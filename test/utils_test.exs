defmodule Archive.UtilsTest do
  use ExUnit.Case, async: true
  alias Archive.{Entry, Utils, Stat, Nif}

  test "formats sizes at every unit boundary" do
    assert Utils.format_size(0) == "0 B"
    assert Utils.format_size(1023) == "1023 B"
    assert Utils.format_size(1024) == "1.0 KB"
    assert Utils.format_size(1024 * 1024) == "1.0 MB"
    assert Utils.format_size(1024 * 1024 * 1024) == "1.0 GB"
    assert Utils.format_size(nil) == "unknown size"
  end

  test "builds directory trees independent of explicit directory order" do
    e = Entry.from_binary("a/b.txt", "body")
    d = %{Entry.from_binary("a/", "") | stat: %File.Stat{type: :directory, size: 0}}
    assert Utils.hierarchical([e, d]) == %{"a" => %{"b.txt" => e}}
    assert Utils.hierarchical([d, e]) == Utils.hierarchical([e, d])
    assert Utils.hierarchical([%{e | path: ""}]) == %{}
    assert Utils.hierarchical(nil) == %{}
  end

  test "extract flags combine named flags and accept explicit masks" do
    {:ok, opts} = Utils.handle_extract_opts(flags: [:perm, :time, :acl])

    assert opts[:flags] ==
             Bitwise.bor(
               Bitwise.bor(Nif.extractFlagToInt(:perm), Nif.extractFlagToInt(:time)),
               Nif.extractFlagToInt(:acl)
             )

    assert {:ok, [flags: 0]} = Utils.handle_extract_opts(flags: [])
    assert {:ok, [flags: 12]} = Utils.handle_extract_opts(flags: 12)
    assert {:ok, [flags: 2]} = Utils.handle_extract_opts(flags: [:perm])
    assert {:ok, _} = Utils.handle_extract_opts()
    assert {:error, _} = Utils.handle_extract_opts(flags: -1)
  end

  test "stat round trips calendar and Unix timestamps with inode and link count" do
    entry = Entry.from_binary("file", "abc")

    for time <- [0, 1_700_000_000, {{2024, 1, 2}, {3, 4, 5}}, :undefined, nil] do
      stat = %{entry.stat | atime: time, mtime: time, ctime: time, inode: 123, links: 7}
      native = Nif.archive_entry_new()
      assert :ok = Nif.archive_entry_copy_stat(native, Stat.file_stat_to_native_map(stat))
      result = native |> Nif.archive_entry_stat() |> Stat.to_file_stat()
      assert result.inode == 123
      assert result.links == 7
      assert result.size == 3
      assert result.type == :regular
      assert result.access == :read_write
      Nif.archive_entry_free(native)
    end

    zero = %{entry.stat | size: :undefined, inode: nil, uid: :unknown, gid: :undefined}
    assert Stat.file_stat_to_native_map(zero).size == 0
  end

  test "portable stat conversion supports both time layouts and all access bits" do
    common = %{gid: 1, uid: 2, ino: 3, nlink: 1, size: 4, dev: 258, rdev: 2}

    for {mode, access, type} <- [
          {0o100600, :read_write, :regular},
          {0o040400, :read, :directory},
          {0o120200, :write, :symlink},
          {0, :none, :other}
        ] do
      times = %{atim: %{sec: 0, nsec: 0}, mtim: %{sec: 1, nsec: 2}, ctim: %{sec: 2, nsec: 0}}
      result = Stat.to_file_stat(Map.merge(common, Map.put(times, :mode, mode)))
      assert {result.access, result.type} == {access, type}
      assert result.atime == {{1970, 1, 1}, {0, 0, 0}}
      assert result.major_device == 258
      assert result.minor_device == 2
    end

    assert Stat.combine_major_minor(1, 2) == 258
    assert Stat.combine_major_minor(-10, 999) == 255
    assert Stat.major_minor(%{dev: 258}) == %{major_device: 258, minor_device: 0}
    assert Stat.file_kinds().file == 0o100000
  end

  test "File.Stat preserves full device identifiers through native conversion" do
    stat = File.stat!(__ENV__.file, time: :posix)
    native = Nif.archive_entry_new()

    try do
      Nif.archive_entry_copy_stat(native, Stat.file_stat_to_native_map(stat))
      result = native |> Nif.archive_entry_stat() |> Stat.to_file_stat()
      assert result.major_device == stat.major_device
      assert result.minor_device == stat.minor_device
    after
      Nif.archive_entry_free(native)
    end
  end

  test "inspect shows archive summaries, trees, loaded state and truncation" do
    list = [
      Entry.from_binary("nested/a", "aaa"),
      Entry.from_binary("nested/b", "bb"),
      Entry.from_binary("other", "x"),
      Entry.from_binary("last", "x")
    ]

    archive = %Archive{description: "tar", entries: list}
    text = inspect(archive, pretty: true, custom_options: [depth: 3, breadth: 2])
    assert text =~ "4 entries (4 loaded)"
    tree = %{archive | entries: Archive.Utils.hierarchical(list)}
    assert inspect(tree, pretty: true) =~ "4 entries (4 loaded)"
    assert text =~ "and"
    assert inspect(archive, pretty: true, custom_options: [depth: 1, breadth: 9]) =~ "nested/"
    assert inspect(%Archive{}) =~ "initialized"
    assert inspect(%Archive{entries: %{}}) =~ "initialized"
    assert inspect(%Archive{entries: %{"x" => Entry.from_binary("x", "ok")}}) =~ "1 entries"
    assert inspect(Entry.from_binary("x", "ok")) =~ "loaded"
    e = %{Entry.from_binary("x", "") | data: nil}
    assert inspect(e) =~ "not loaded"
    assert inspect(Archive.reader!("raw", as: :data)) =~ ":raw"
    assert inspect(Archive.writer!("file.zip", format: :zip)) =~ "zip"
    assert inspect(Archive.stream!()) == "#Archive.Stream<>"

    for mode <- [0o140000, 0o120000, 0o100000, 0o060000, 0o040000, 0o020000, 0o010000, 0] do
      e = %{e | stat: %{e.stat | mode: mode, mtime: {{1970, 1, 1}, {0, 0, 0}}}}
      assert inspect(e) =~ "mtime:"
    end
  end

  test "error messages include native diagnostics and various reasons" do
    for reason <- [:bad, "bad", RuntimeError.exception("bad"), %{problem: "bad"}] do
      text = Exception.message(%Archive.Error{reason: reason, path: "file", action: "read"})
      assert text =~ "bad"
      assert text =~ "libarchive details"
    end
  end
end
