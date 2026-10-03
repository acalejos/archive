defmodule ArchiveTest do
  use ExUnit.Case, async: true
  alias Archive.Entry

  setup do
    dir = Path.join(System.tmp_dir!(), "archive-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "sample.tar")}
  end

  defp entries do
    [
      Entry.from_binary("nested/hello.txt", "hello"),
      Entry.from_binary("empty", ""),
      Entry.from_binary("日本語.txt", <<0, 255, 1, 2>>)
    ]
  end

  defp contents(stream), do: Enum.map(stream, &{&1.path, Entry.read_data!(&1, stream).data})

  test "collects bodies and traverses a descriptor repeatedly", %{path: path} do
    writer = Archive.writer!(path)
    assert Enum.into(entries(), writer) == writer
    reader = Archive.reader!(path)
    assert contents(reader) == Enum.map(entries(), &{&1.path, &1.data})
    assert contents(reader) == contents(reader)
    assert Enum.count(reader) == 3
    assert Enum.member?(Stream.map(reader, & &1.path), "empty")
    assert Enum.slice(reader, 1, 1) |> Enum.map(& &1.path) == ["empty"]
  end

  test "copies bodies without loading them, filters and renames lazily", %{dir: dir, path: path} do
    Archive.write!(entries(), path)
    source = Archive.reader!(path)
    target = Path.join(dir, "result.zip")

    result =
      source
      |> Stream.reject(&(&1.path == "empty"))
      |> Stream.map(&%{&1 | path: "copy/" <> &1.path})
      |> Enum.into(Archive.writer!(target, format: :zip))

    assert %Archive.Stream{} = result

    assert contents(Archive.reader!(target)) == [
             {"copy/nested/hello.txt", "hello"},
             {"copy/日本語.txt", <<0, 255, 1, 2>>}
           ]
  end

  test "stream transformations preserve native timestamp precision", %{path: path, dir: dir} do
    alias Archive.Nif, as: N
    writer = N.archive_write_new()
    header = N.archive_entry_new()

    try do
      N.archive_write_set_format_pax(writer)
      N.archive_write_open_filename(writer, path)
      N.archive_entry_set_pathname(header, "precise")
      N.archive_entry_set_mode(header, 0o100644)
      N.archive_entry_set_size(header, 3)
      N.archive_entry_set_mtime(header, 1_700_000_000, 123_456_789)
      N.archive_write_header(writer, header)
      assert N.archive_write_data(writer, "abc") == 3
      N.archive_write_close(writer)
    after
      N.archive_entry_free(header)
      N.archive_write_free(writer)
    end

    target = Path.join(dir, "precise.tar")

    Archive.reader!(path)
    |> Stream.map(fn entry ->
      entry = Entry.read_data!(entry)
      %{entry | path: "renamed", data: "abcd", stat: %{entry.stat | size: 4}}
    end)
    |> Enum.into(Archive.writer!(target, format: :tar_pax_interchange))

    Enum.each(Archive.reader!(target), fn entry ->
      assert entry.path == "renamed"
      assert N.archive_entry_mtime_nsec(entry.source.entry) == 123_456_789
      assert Entry.read_data!(entry).data == "abcd"
    end)
  end

  test "supports body transforms with updated sizes", %{dir: dir, path: path} do
    Archive.write!(entries(), path)
    source = Archive.reader!(path)
    output = Path.join(dir, "upper.tar")

    source
    |> Stream.map(fn entry ->
      entry = Entry.read_data!(entry)
      data = entry.data <> "!"
      %{entry | data: data, stat: %{entry.stat | size: byte_size(data)}}
    end)
    |> Enum.into(Archive.writer!(output))

    assert Enum.map(contents(Archive.reader!(output)), &elem(&1, 1)) == [
             "hello!",
             "!",
             <<0, 255, 1, 2, 33>>
           ]
  end

  test "entry bodies are bounded chunks and binary loads are idempotent", %{path: path} do
    Archive.write!([Entry.from_binary("big", String.duplicate("abc", 100_000))], path)
    reader = Archive.reader!(path)

    Enum.each(reader, fn entry ->
      chunks = Enum.to_list(Entry.data_stream(entry, 4096))
      assert Enum.all?(chunks, &(byte_size(&1) <= 4096))
      assert IO.iodata_to_binary(chunks) == String.duplicate("abc", 100_000)
    end)

    assert Entry.read_data!(Entry.from_binary("x", "ok")).data == "ok"

    assert Enum.to_list(Entry.data_stream(Entry.from_binary("x", "abcdef"), 2)) == [
             "ab",
             "cd",
             "ef"
           ]

    assert_raise ArgumentError, fn -> Entry.data_stream(Entry.from_binary("x", ""), 0) end
    assert_raise ArgumentError, fn -> Entry.data_stream(Entry.new!(stat: %File.Stat{size: 1})) end
  end

  test "entry lifetime checks prevent reading another entry's bytes", %{path: path} do
    Archive.write!(entries(), path)
    stream = Archive.reader!(path)

    Enum.reduce(stream, nil, fn entry, previous ->
      if previous, do: assert_raise(Archive.Error, fn -> Entry.read_data!(previous) end)
      entry
    end)

    expired = Enum.at(stream, 0)
    assert {:error, %ErlangError{}} = Entry.read_data(expired)
  end

  test "early halt, exceptions, nested and concurrent traversals clean up", %{path: path} do
    Archive.write!(entries(), path)
    source = Archive.reader!(path)
    assert length(Enum.take(source, 1)) == 1
    assert_raise RuntimeError, "stop", fn -> Enum.each(source, fn _ -> raise "stop" end) end
    assert Enum.map(source, fn _ -> Enum.count(source) end) == [3, 3, 3]
    assert length(Enum.zip(source, source)) == 3

    assert Task.async_stream(1..6, fn _ -> contents(source) end)
           |> Enum.all?(fn {:ok, values} -> length(values) == 3 end)
  end

  test "enumeration is suspended and resumed correctly", %{path: path} do
    Archive.write!(entries(), path)
    source = Archive.reader!(path)

    {:suspended, [first], continue} =
      Enumerable.reduce(source, {:cont, []}, fn e, acc -> {:suspend, [e | acc]} end)

    assert first.path == "nested/hello.txt"
    assert Entry.read_data!(first).data == "hello"
    {:suspended, [second, ^first], continue} = continue.({:cont, [first]})
    assert second.path == "empty"
    assert {:halted, _} = continue.({:halt, [second, first]})
    assert Enum.count(source) == 3
  end

  test "reads binary archives, including after original input GC", %{path: path} do
    Archive.write!(entries(), path)
    data = File.read!(path)
    reader = Archive.reader!(data, as: :data)
    assert Enum.count(reader) == 3
    assert contents(reader) == contents(Archive.reader!(path, as: :file))
    assert Enum.count(Archive.reader!(data)) == 3
  end

  for {format, filters} <- [
        {:tar, :none},
        {:tar_pax_restricted, :gzip},
        {:tar_gnutar, :bzip2},
        {:tar, :xz},
        {:tar, :lz4},
        {:tar, :zstd},
        {:zip, :none},
        {:cpio_posix, :none},
        {:sevenz, :none}
      ] do
    test "round trips #{format} with #{filters}", %{path: path} do
      Archive.write!(entries(), path, format: unquote(format), filters: unquote(filters))

      assert Enum.sort(contents(Archive.reader!(path))) ==
               Enum.sort(Enum.map(entries(), &{&1.path, &1.data}))
    end
  end

  test "streams disk files and catches changing size", %{dir: dir, path: path} do
    file = Path.join(dir, "input")
    File.write!(file, "from disk")
    entry = Entry.from_file(file, path: "disk.txt", chunk_size: 2)
    Archive.write!([entry], path)
    assert contents(Archive.reader!(path)) == [{"disk.txt", "from disk"}]
    File.write!(file, "a")
    assert {:error, %Archive.Error{reason: :SizeMismatch}} = Archive.write([entry], path)
  end

  test "collector errors close the writer while the collector remains referenced", %{path: path} do
    alias Archive.Nif, as: N
    {active, collect} = Collectable.into(Archive.writer!(path))
    probe = N.archive_resource_probe(active.writer.ref)
    entry = Entry.from_binary("wrong-size", "body")
    entry = %{entry | stat: %{entry.stat | size: 5}}

    assert_raise Archive.Error, fn -> collect.(active, {:cont, entry}) end
    assert N.archive_resource_stats(probe).freed == 1
    assert :ok = collect.(active, :halt)
    assert N.archive_resource_stats(probe).freed == 1
    assert :ok = File.rm(path)
  end

  test "freeing a failed native writer releases its filename descriptor", %{path: path} do
    alias Archive.Nif, as: N
    writer = N.archive_write_new()
    N.archive_write_set_format_pax(writer)
    N.archive_write_open_filename(writer, path)

    open? = fn ->
      File.ls!("/proc/self/fd")
      |> Enum.any?(fn fd -> File.read_link("/proc/self/fd/" <> fd) == {:ok, path} end)
    end

    if File.dir?("/proc/self/fd"), do: assert(open?.())
    assert N.archive_write_fail(writer) > 0
    N.archive_write_free(writer)
    if File.dir?("/proc/self/fd"), do: refute(open?.())
    assert :ok = File.rm(path)
  end

  test "retains symlink and hardlink metadata", %{path: path} do
    plain = Entry.from_binary("plain", "hello")

    link = %{
      Entry.from_binary("link", "")
      | symlink: "plain",
        stat: %{plain.stat | type: :symlink, mode: 0o120777, size: 0}
    }

    hard = %{Entry.from_binary("hard", "") | hardlink: "plain"}
    Archive.write!([plain, link, hard], path)
    result = Enum.to_list(Archive.reader!(path))
    assert Enum.at(result, 1).symlink == "plain"
    assert Enum.at(result, 2).hardlink == "plain"
  end

  test "high-level reads, indexing and resets aggregate state", %{path: path} do
    Archive.write!(entries(), path)
    stream = Archive.reader!(path)
    indexed = Archive.index(Archive.new(), stream)
    assert indexed.count == 3
    assert indexed.total_size == 9
    assert Archive.update_entries(indexed, stream).total_size == 9
    assert %Archive{count: 3, entries: [%{data: "hello"}, _, _]} = Archive.read!(path, load: true)
    assert Archive.read!(path).total_size == 9
    assert Archive.read!(path).format in [:tar_pax_restricted, :tar_pax_interchange, :tar_ustar]
    assert %Archive{entries: []} = Archive.read!(<<0::size(8192)>>, as: :data)
  end

  test "disk entry construction preserves symbolic links", %{dir: dir, path: path} do
    file = Path.join(dir, "original")
    link = Path.join(dir, "link")
    File.write!(file, "body")
    target = if match?({:win32, _}, :os.type()), do: file, else: "original"
    File.ln_s!(target, link)
    reported_target = File.read_link!(link)

    if match?({:win32, _}, :os.type()),
      do: assert(File.read!(reported_target) == "body"),
      else: assert(reported_target == target)

    entry = Entry.from_file(link)
    assert entry.stat.type == :symlink
    assert Bitwise.band(entry.stat.mode, 0o170000) == 0o120000
    assert entry.symlink == reported_target
    assert entry.data == nil
    Archive.write!([entry], path)
    [result] = Enum.to_list(Archive.reader!(path))
    assert result.symlink == reported_target
    assert result.stat.type == :symlink
  end

  test "reads and writes Unicode archive filenames", %{dir: dir} do
    path = Path.join(dir, "日本語.tar")
    Archive.write!(entries(), path)
    assert contents(Archive.reader!(path)) == Enum.map(entries(), &{&1.path, &1.data})
  end

  test "validates options and reports corruption instead of truncating success", %{dir: dir} do
    assert {:error, %NimbleOptions.ValidationError{}} = Archive.reader("x", formats: :unknown)
    assert_raise NimbleOptions.ValidationError, fn -> Archive.writer!("x", format: :unknown) end
    assert {:error, _} = Archive.stream(writer: true)
    assert_raise ArgumentError, fn -> Enum.to_list(Archive.writer!("x")) end
    assert_raise ArgumentError, fn -> Enum.into([], Archive.reader!("x")) end
    assert {:error, %Archive.Error{}} = Archive.read("not an archive", as: :data, formats: :tar)
    assert {:error, %Archive.Error{}} = Archive.read(Path.join(dir, "missing"), as: :file)
    assert {:error, %Archive.Error{}} = Archive.write(entries(), Path.join(dir, "missing/output"))
  end

  test "truncated bodies fail during streaming and collection", %{path: path, dir: dir} do
    Archive.write!([Entry.from_binary("large", String.duplicate("x", 5000))], path)
    truncated = File.read!(path) |> binary_part(0, 1024)
    source = Archive.reader!(truncated, as: :data, formats: :tar)
    assert_raise Archive.Error, fn -> contents(source) end

    assert_raise Archive.Error, fn ->
      Enum.into(source, Archive.writer!(Path.join(dir, "partial.tar")))
    end

    assert {:error, %Archive.Error{}} = Archive.read(truncated, as: :data, load: true)
  end

  test "only and except options expand correctly", %{path: path} do
    Archive.write!(entries(), path)

    assert Enum.count(Archive.reader!(path, formats: [only: [:tar]], filters: [only: [:none]])) ==
             3

    assert Enum.count(Archive.reader!(path, formats: [except: [:zip]], filters: [except: [:rpm]])) ==
             3

    assert Enum.count(Archive.reader!(path, formats: :tar, filters: :none)) == 3
    assert Enum.count(Archive.reader!(path, formats: [:tar])) == 3
    assert %Archive.Stream{} = Archive.stream!()
    assert :ok = Archive.Stream.close(Archive.stream!())
  end

  test "extracts with flags, prefix and destination", %{dir: dir, path: path} do
    Archive.write!(entries(), path)
    dest = Path.join(dir, "extracted")
    assert :ok = Archive.extract(Archive.reader!(path), to: dest, flags: [:perm, :time])
    assert File.read!(Path.join(dest, "nested/hello.txt")) == "hello"
    stream = Archive.reader!(path)

    Enum.each(stream, fn entry ->
      assert :ok = Entry.extract(entry, stream, to: Path.join(dir, "prefixed"), prefix: "p-")
    end)

    assert File.read!(Path.join(dir, "prefixed/p-nested/hello.txt")) == "hello"
  end

  test "extraction rejects traversal and propagates errors", %{dir: dir, path: path} do
    Archive.write!([Entry.from_binary("../outside", "evil")], path)

    assert_raise Archive.Error, fn ->
      Archive.extract!(Archive.reader!(path), to: Path.join(dir, "safe"))
    end

    refute File.exists?(Path.join(dir, "outside"))
    File.write!(Path.join(dir, "regular"), "x")
    assert {:error, _} = Archive.Utils.handle_extract_opts(to: Path.join(dir, "regular"))
    assert {:error, _} = Archive.Utils.handle_extract_opts(flags: [:bad])
  end

  test "configures native options and encrypted ZIP passphrases", %{path: path} do
    assert {:ok, _} = Archive.Stream.new()
    assert {:ok, _} = Archive.stream()

    assert {:ok, writer} =
             Archive.writer(path,
               format: :zip,
               options: "zip:encryption=aes256",
               passphrase: "secret"
             )

    Enum.into([Entry.from_binary("secret.txt", "hidden")], writer)

    assert {:ok, reader} =
             Archive.reader(path, options: "zip:ignorecrc32", passphrases: ["secret"])

    assert contents(reader) == [{"secret.txt", "hidden"}]
    assert {:ok, %Archive{count: 1}} = Archive.list(path)
    assert {:error, _} = Archive.read(path, load: true)

    assert {:ok, active} =
             Archive.writer!(path, filters: :all)
             |> Map.update!(:writer, &%{&1 | filters: [:none]})
             |> Archive.Stream.init()

    assert :ok = Archive.Stream.close(active)

    assert {:error, %Archive.Error{}} =
             Archive.writer!(path, options: "no-such-option") |> Archive.Stream.init()

    assert {:error, %Archive.Error{}} =
             Archive.reader!(path, options: "no-such-option") |> Archive.Stream.init()
  end

  test "validates hardlink extraction and protects destination symlinks", %{dir: dir, path: path} do
    hard = %{Entry.from_binary("hard", "") | hardlink: "plain"}
    Archive.write!([Entry.from_binary("plain", "hello"), hard], path)
    dest = Path.join(dir, "links")
    assert :ok = Archive.extract(Archive.reader!(path), to: dest)
    assert File.read!(Path.join(dest, "hard")) == "hello"
    assert File.stat!(Path.join(dest, "hard")).inode == File.stat!(Path.join(dest, "plain")).inode
    outside = Path.join(dir, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(dest, "redirect"))
    Archive.write!([Entry.from_binary("redirect/escape", "bad")], path)
    assert_raise Archive.Error, fn -> Archive.extract!(Archive.reader!(path), to: dest) end
    refute File.exists?(Path.join(outside, "escape"))
    absolute = Path.join(dir, "absolute")
    Archive.write!([Entry.from_binary(absolute, "ok")], path)
    assert_raise Archive.Error, fn -> Archive.extract!(Archive.reader!(path)) end
    reader = Archive.reader!(path)
    Enum.each(reader, fn entry -> assert :ok = Entry.extract(entry, reader, flags: []) end)
    assert File.read!(absolute) == "ok"
  end

  test "default constructors and protocol fallback functions", %{dir: dir, path: path} do
    Archive.write!([Entry.from_binary("one", "one")], path)
    assert {:ok, _} = Archive.reader(path)
    assert {:ok, _} = Archive.writer(path)
    assert {:ok, _} = Archive.read(path)
    assert {:ok, _} = Archive.Entry.new()
    assert %Entry{} = Entry.from_file(dir)
    assert Enum.to_list(Entry.data_stream(Entry.new!(stat: %File.Stat{size: 0}))) == []
    reader = Archive.reader!(path)
    assert Enumerable.count(reader) == {:error, Enumerable.Archive.Stream}
    assert Enumerable.slice(reader) == {:error, Enumerable.Archive.Stream}
    assert Enumerable.member?(reader, :anything) == {:error, Enumerable.Archive.Stream}
    refute Enum.member?(reader, :anything)
    known = %Archive{format: :tar, compression: :none, description: "known"}
    assert Archive.update_info(known, reader) == known
  end
end
