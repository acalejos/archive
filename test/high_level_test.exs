defmodule Archive.HighLevelTest do
  use ExUnit.Case, async: true
  alias Archive.Entry

  setup do
    dir = Path.join(System.tmp_dir!(), "archive-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "input.tar")

    entries = [
      Entry.from_binary("same", "first"),
      Entry.from_binary("same", "second"),
      Entry.from_binary("empty", "")
    ]

    :ok = Archive.write!(entries, path)
    %{dir: dir, path: path, bytes: File.read!(path)}
  end

  test "listing returns ordered detached metadata and stable totals", %{path: path} do
    assert {:ok, archive} = Archive.list(path)
    assert archive.count == 3
    assert archive.total_size == 11
    assert inspect(archive, pretty: true) =~ "3 entries (0 loaded)"
    assert Enum.map(archive.entries, & &1.path) == ["same", "same", "empty"]
    assert Enum.all?(archive.entries, &(is_nil(&1.source) and is_nil(&1.data)))
    assert Enum.all?(archive.entries, &is_reference(&1.native))
    assert archive.description =~ "tar"
    assert Archive.new().count == 0
    assert {:error, %Archive.Error{reason: :BodyNotLoaded}} = Archive.write(archive, path)
  end

  test "reads retain bodies and snapshots can be written after traversal", %{path: path, dir: dir} do
    archive = Archive.read!(path)
    assert inspect(archive, pretty: true) =~ "3 entries (3 loaded)"
    assert Enum.map(archive.entries, & &1.data) == ["first", "second", ""]
    assert Enum.all?(archive.entries, &is_nil(&1.source))
    assert Archive.Entry.read_data!(hd(archive.entries)) == hd(archive.entries)
    output = Path.join(dir, "output.zip")
    assert :ok = Archive.write(archive, output, format: :zip)
    assert Enum.map(Archive.read!(output).entries, & &1.data) == ["first", "second", ""]
    assert Enum.all?(Archive.read!(path, load: false).entries, &is_nil(&1.data))
  end

  test "retained snapshots preserve native metadata and allow timestamp edits", %{
    path: path,
    dir: dir
  } do
    alias Archive.Nif, as: N
    archive = Archive.read!(path)
    entry = hd(archive.entries)
    N.archive_entry_set_mtime(entry.native, 0, 123_456_789)
    N.archive_entry_xattr_add_entry(entry.native, "user.saved", <<0, 255>>)
    N.archive_entry_unset_atime(entry.native)
    N.archive_entry_unset_ctime(entry.native)
    N.archive_entry_unset_birthtime(entry.native)
    output = Path.join(dir, "metadata.tar")
    Archive.write!([entry], output, format: :tar_pax_interchange)
    retained = Archive.fetch!(output, "same")
    assert retained.data == "first"
    assert N.archive_entry_mtime_nsec(retained.native) == 123_456_789
    assert N.archive_entry_xattr_reset(retained.native) > 0
    assert N.archive_entry_xattr_next(retained.native) == %{name: "user.saved", value: <<0, 255>>}
    assert N.archive_entry_atime_is_set(retained.native) == 0
    assert N.archive_entry_ctime_is_set(retained.native) == 0
    assert N.archive_entry_birthtime_is_set(retained.native) == 0

    changed = %{entry | stat: %{entry.stat | mtime: {{1970, 1, 1}, {0, 1, 0}}}}
    Archive.write!([changed], output, format: :tar_pax_interchange)
    edited = Archive.fetch!(output, "same")
    assert N.archive_entry_mtime(edited.native) == 60
    assert N.archive_entry_mtime_nsec(edited.native) == 0
  end

  test "tagged file and data sources and configured descriptors share operations", %{
    path: path,
    bytes: bytes
  } do
    for source <- [{:file, path}, {:data, bytes}, Archive.reader!(path)] do
      assert Archive.list!(source).count == 3
      assert hd(Archive.read!(source).entries).data == "first"
      assert Archive.fetch!(source, "same").data == "first"
    end

    assert {:ok, %{count: 3}} = Archive.list(bytes, as: :data)
    assert {:ok, _} = Archive.list({:data, bytes}, as: :auto)
    assert {:error, %ArgumentError{}} = Archive.read({:data, bytes}, as: :file)
    assert {:error, %ArgumentError{}} = Archive.list({:file, path}, as: :data)
    assert {:error, %ArgumentError{}} = Archive.read(Archive.reader!(path), formats: :tar)
    assert {:error, %ArgumentError{}} = Archive.list(Archive.writer!(path))
    assert {:error, %ArgumentError{}} = Archive.list(:invalid)
  end

  test "missing bare paths are file errors and invalid options return errors", %{
    dir: dir,
    path: path
  } do
    missing = Path.join(dir, "missing.tar")
    assert {:error, %Archive.Error{}} = Archive.read(missing)
    assert_raise Archive.Error, fn -> Archive.list!(missing) end
    assert {:error, %NimbleOptions.ValidationError{}} = Archive.read(path, load: :sometimes)
    assert {:error, %NimbleOptions.ValidationError{}} = Archive.list(path, formats: :unknown)
    assert {:error, %NimbleOptions.ValidationError{}} = Archive.write([], path, format: :unknown)
    assert {:error, %Archive.Error{}} = Archive.list({:data, "not an archive"})
    assert_raise NimbleOptions.ValidationError, fn -> Archive.read!(path, load: 42) end

    assert_raise NimbleOptions.ValidationError, fn ->
      Archive.write!([], path, format: :unknown)
    end
  end

  test "fetch chooses the first exact duplicate, detaches its body, and reports absence", %{
    path: path
  } do
    assert {:ok, %{path: "same", data: "first", source: nil}} = Archive.fetch(path, "same")
    assert Archive.fetch!(path, "empty").data == ""

    assert {:error, %Archive.Error{reason: :EntryNotFound, path: "./same"}} =
             Archive.fetch(path, "./same")

    assert_raise Archive.Error, fn -> Archive.fetch!(path, "absent") end

    assert {:error, %NimbleOptions.ValidationError{}} =
             Archive.fetch(path, "same", formats: :unknown)
  end

  test "fetch halts before a later truncated body", %{dir: dir} do
    path = Path.join(dir, "truncated.tar")

    Archive.write!(
      [
        Entry.from_binary("first", "abc"),
        Entry.from_binary("large", String.duplicate("x", 5000))
      ],
      path
    )

    data = File.read!(path) |> binary_part(0, 1540)
    assert Archive.fetch!({:data, data}, "first").data == "abc"
    assert {:error, %Archive.Error{}} = Archive.read({:data, data})
  end

  test "extraction accepts sources and returns errors; bang variant raises", %{
    path: path,
    bytes: bytes,
    dir: dir
  } do
    destination = Path.join(dir, "extracted")
    assert :ok = Archive.extract(path, to: destination)
    assert File.read!(Path.join(destination, "same")) == "second"
    assert :ok = Archive.extract!({:data, bytes}, to: destination, reader: [formats: :tar])
    assert {:error, %NimbleOptions.ValidationError{}} = Archive.extract(path, flags: [:unknown])

    assert {:error, %NimbleOptions.ValidationError{}} =
             Archive.extract(path, reader: [formats: :unknown])

    assert {:error, %ArgumentError{}} = Archive.extract(:invalid, to: destination)
    assert {:error, %Archive.Error{}} = Archive.extract({:data, "bad"}, to: destination)
    assert_raise Archive.Error, fn -> Archive.extract!({:data, "bad"}, to: destination) end
  end

  test "secure extraction errors are returned and not silently accepted", %{dir: dir} do
    path = Path.join(dir, "unsafe.tar")
    Archive.write!([Entry.from_binary("../escape", "bad")], path)
    assert {:error, %Archive.Error{}} = Archive.extract(path, to: Path.join(dir, "safe"))
    refute File.exists?(Path.join(dir, "escape"))
  end

  test "stream-to-file write stays bounded and returns no writer state", %{path: path, dir: dir} do
    output = Path.join(dir, "streamed.zip")
    stream = Archive.reader!(path) |> Stream.map(&%{&1 | path: "prefix/" <> &1.path})
    assert :ok = Archive.write(stream, output, format: :zip)
    assert Archive.fetch!(output, "prefix/same").data == "first"
  end

  test "empty snapshots have stable counts", %{dir: dir} do
    path = Path.join(dir, "empty.zip")
    Archive.write!([], path, format: :zip)

    for operation <- [&Archive.list!/1, &Archive.read!/1] do
      assert %Archive{entries: [], count: 0, total_size: 0, format: :zip, compression: :none} =
               operation.(path)
    end
  end
end
