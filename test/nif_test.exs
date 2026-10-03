defmodule Archive.NifTest do
  use ExUnit.Case, async: true
  alias Archive.Nif, as: N

  test "the header inventory is complete and every supported symbol is exported" do
    Code.ensure_loaded!(N)
    {bindings, _} = Code.eval_file(Path.expand("../priv/bindings.exs", __DIR__))
    assert length(bindings) > 400

    for {name, _, arity, _} <- bindings,
        do: assert(function_exported?(N, name, arity), "missing #{name}/#{arity}")
  end

  test "versions and enum conversions" do
    assert N.archive_version_number() >= 3_008_009
    assert N.archive_version_string() =~ "libarchive"
    assert N.archive_version_details() =~ "libarchive"

    for name <- [
          :archive_zlib_version,
          :archive_liblzma_version,
          :archive_bzlib_version,
          :archive_liblz4_version,
          :archive_libzstd_version
        ] do
      version = apply(N, name, [])
      assert is_nil(version) or is_binary(version)
    end

    for kind <- [:formats, :filters], direction <- [:read, :write] do
      values = N.list_all(kind, direction)
      assert :tar in values or :none in values

      for value <- values do
        {encode, decode} =
          if kind == :formats,
            do: {&N.archiveFormatToInt/1, &N.archiveFormatToAtom/1},
            else: {&N.archiveFilterToInt/1, &N.archiveFilterToAtom/1}

        assert decode.(encode.(value)) == value
      end
    end

    assert N.isSubFormatOf(:tar_pax_restricted, :tar)
    refute N.isSubFormatOf(:zip, :tar)
    assert N.archiveFormatToAtom(-1) == nil
    assert N.archiveFilterToAtom(-1) == nil
    assert N.constants()[:ARCHIVE_OK] == 0
  end

  for {field, value} <- [
        size: 321,
        uid: 123,
        gid: 456,
        ino: 234,
        ino64: 345,
        nlink: 2,
        mode: 0o100640,
        perm: 0o644,
        filetype: 0o100000,
        dev: 123,
        devmajor: 1,
        devminor: 2,
        rdev: 789,
        rdevmajor: 3,
        rdevminor: 4,
        symlink_type: 1
      ] do
    test "sets and reads entry #{field}" do
      entry = N.archive_entry_new()

      assert :ok =
               apply(N, unquote(String.to_atom("archive_entry_set_#{field}")), [
                 entry,
                 unquote(value)
               ])

      assert apply(N, unquote(String.to_atom("archive_entry_#{field}")), [entry]) ==
               unquote(value)

      assert :ok = N.archive_entry_free(entry)
    end
  end

  for field <- [:atime, :birthtime, :ctime, :mtime] do
    test "sets, reads and unsets #{field}" do
      entry = N.archive_entry_new()

      assert :ok =
               apply(N, unquote(String.to_atom("archive_entry_set_#{field}")), [
                 entry,
                 1_700_000_000,
                 123_456_789
               ])

      assert apply(N, unquote(String.to_atom("archive_entry_#{field}")), [entry]) == 1_700_000_000

      assert apply(N, unquote(String.to_atom("archive_entry_#{field}_nsec")), [entry]) ==
               123_456_789

      assert apply(N, unquote(String.to_atom("archive_entry_#{field}_is_set")), [entry]) != 0
      assert :ok = apply(N, unquote(String.to_atom("archive_entry_unset_#{field}")), [entry])
      assert apply(N, unquote(String.to_atom("archive_entry_#{field}_is_set")), [entry]) == 0
    end
  end

  for field <- [:pathname, :symlink, :hardlink, :uname, :gname], suffix <- ["", "_utf8", "_w"] do
    test "copies and reads #{field}#{suffix}, including UTF-8 and nulls" do
      entry = N.archive_entry_new()

      setter =
        unquote(
          String.to_atom(
            if suffix == "_w",
              do: "archive_entry_copy_#{field}_w",
              else: "archive_entry_set_#{field}#{suffix}"
          )
        )

      getter = unquote(String.to_atom("archive_entry_#{field}#{suffix}"))
      assert :ok = apply(N, setter, [entry, "日本語/name"])
      assert apply(N, getter, [entry]) == "日本語/name"
      assert :ok = apply(N, setter, [entry, nil])
      assert apply(N, getter, [entry]) == nil
    end
  end

  test "clone and clear have independent ownership; free is idempotent" do
    original = N.archive_entry_new()
    N.archive_entry_set_pathname(original, "original")
    clone = N.archive_entry_clone(original)
    N.archive_entry_set_pathname(clone, "clone")
    assert N.archive_entry_pathname(original) == "original"
    assert N.archive_entry_pathname(clone) == "clone"
    assert :ok = N.archive_entry_clear(clone)
    assert N.archive_entry_pathname(clone) == nil
    assert :ok = N.archive_entry_free(original)
    assert :ok = N.archive_entry_free(original)
    assert {:error, :EntryClosed} = N.safe_call(fn -> N.archive_entry_size(original) end)
  end

  test "error strings preserve UTF-8 and format strings are literal" do
    ref = N.archive_read_new()
    assert :ok = N.archive_set_error(ref, 42, "日本語 %n")
    assert N.archive_errno(ref) == 42
    assert N.get_error_string(ref) == "日本語 %n"
    assert N.archive_error_string(ref) == nil
    assert :ok = N.archive_read_free(ref)
    assert :ok = N.archive_read_free(ref)
    assert {:error, :ArchiveClosed} = N.safe_call(fn -> N.archive_format(ref) end)
    assert {:ok, 123} = N.safe_call(fn -> 123 end)
    assert :ok = N.safe_call(fn -> :ok end)
    assert {:error, :reason} = N.safe_call(fn -> {:error, :reason} end)
    assert :ok = N.safe_call(fn -> :erlang.error(:ArchiveWarn) end)
    assert {:error, :ArchiveRetry} = N.safe_call(fn -> :erlang.error(:ArchiveRetry) end)
    assert {:error, :Unexpected} = N.safe_call(fn -> :erlang.error(:Unexpected) end)
    assert_raise Archive.Error, fn -> N.unwrap!({:error, :bad}) end
    assert_raise RuntimeError, "bad", fn -> N.unwrap!({:error, RuntimeError.exception("bad")}) end
    assert_raise ArgumentError, fn -> N.unwrap!(:bad) end
    assert N.unwrap!(:ok) == :ok
    assert N.unwrap!({:ok, 1}) == 1
  end

  test "writes and reads an owned memory buffer and handles short reads" do
    writer = N.archive_write_new()
    N.archive_write_set_format_pax_restricted(writer)
    N.archive_write_set_bytes_per_block(writer, 0)
    assert N.archive_write_get_bytes_per_block(writer) == 0
    N.archive_write_set_bytes_in_last_block(writer, 1)
    assert N.archive_write_get_bytes_in_last_block(writer) == 1
    N.archive_write_open_memory(writer, 8192)
    entry = N.archive_entry_new2(writer)
    N.archive_entry_set_pathname(entry, "memory.txt")
    N.archive_entry_set_size(entry, 5)
    N.archive_entry_set_filetype(entry, 0o100000)
    N.archive_entry_set_perm(entry, 0o644)
    N.archive_write_header(writer, entry)
    assert N.archive_write_data(writer, "hello") == 5
    N.archive_write_finish_entry(writer)
    N.archive_write_close(writer)
    data = N.archive_write_memory(writer)
    N.archive_write_free(writer)
    reader = N.archive_read_new()
    N.archive_read_support_format_tar(reader)
    N.archive_read_support_filter_none(reader)
    N.archive_read_open_memory2(reader, data, 128)
    :erlang.garbage_collect()
    N.archive_read_next_header2(reader, entry)
    assert N.archive_entry_pathname(entry) == "memory.txt"
    assert N.archive_read_data(reader, 100) == "hello"
    assert N.archive_read_data(reader, 100) == ""
    assert N.archive_filter_count(reader) >= 1
    assert N.archive_filter_code(reader, 0) == 0
    assert N.archive_filter_name(reader, 0) == "none"
    assert N.archive_filter_bytes(reader, 0) > 0
    assert N.archive_read_header_position(reader) >= 0
    assert N.archive_file_count(reader) == 1
    assert N.archive_read_has_encrypted_entries(reader) <= 0
    assert is_integer(N.archive_read_format_capabilities(reader))

    assert {:error, :ArchiveEof} =
             N.safe_call(fn -> N.archive_read_next_header(reader, entry) end)

    assert {:error, :InvalidArchiveType} = N.safe_call(fn -> N.archive_write_refresh(reader) end)
    assert {:error, :InvalidArchiveType} = N.safe_call(fn -> N.archive_read_refresh(writer) end)
    N.archive_read_close(reader)
    N.archive_read_refresh(reader)
    N.archive_read_free(reader)
    N.archive_write_refresh(writer)
    N.archive_write_free(writer)
  end

  test "xattrs, sparse descriptors, file flags, mac metadata and encryption metadata" do
    e = N.archive_entry_new()
    N.archive_entry_xattr_add_entry(e, "user.binary", <<0, 255>>)
    assert N.archive_entry_xattr_count(e) == 1
    assert N.archive_entry_xattr_reset(e) == 1
    assert N.archive_entry_xattr_next(e) == %{name: "user.binary", value: <<0, 255>>}
    assert {:error, :ArchiveEof} = N.safe_call(fn -> N.archive_entry_xattr_next(e) end)
    N.archive_entry_xattr_clear(e)
    assert N.archive_entry_xattr_count(e) == 0
    N.archive_entry_set_size(e, 1000)
    N.archive_entry_sparse_add_entry(e, 100, 200)
    assert N.archive_entry_sparse_count(e) == 1
    assert N.archive_entry_sparse_reset(e) == 1
    assert N.archive_entry_sparse_next(e) == %{offset: 100, length: 200}
    assert {:error, :ArchiveEof} = N.safe_call(fn -> N.archive_entry_sparse_next(e) end)
    N.archive_entry_sparse_clear(e)
    assert N.archive_entry_sparse_count(e) == 0
    N.archive_entry_set_fflags(e, 1, 2)
    assert N.archive_entry_fflags(e) == %{set: 1, clear: 2}
    N.archive_entry_copy_mac_metadata(e, <<0, 1, 255>>)
    assert N.archive_entry_mac_metadata(e) == <<0, 1, 255>>
    N.archive_entry_set_is_data_encrypted(e, 1)
    N.archive_entry_set_is_metadata_encrypted(e, 1)
    assert N.archive_entry_is_data_encrypted(e) == 1
    assert N.archive_entry_is_metadata_encrypted(e) == 1
    assert N.archive_entry_is_encrypted(e) != 0

    for kind <- 1..6 do
      size = Enum.at([16, 20, 20, 32, 48, 64], kind - 1)
      digest = :binary.copy(<<kind>>, size)
      N.archive_entry_set_digest(e, kind, digest)
      assert N.archive_entry_digest(e, kind) == digest
    end

    assert {:error, :InvalidDigestSize} =
             N.safe_call(fn -> N.archive_entry_set_digest(e, 4, "short") end)

    assert {:error, :InvalidDigest} = N.safe_call(fn -> N.archive_entry_digest(e, 9) end)
  end

  test "ACL text and iteration" do
    e = N.archive_entry_new()
    c = N.constants()

    N.archive_entry_acl_from_text(
      e,
      "user::rw-,user:123:r--,group::r--,mask::r--,other::---",
      c[:ARCHIVE_ENTRY_ACL_TYPE_ACCESS]
    )

    assert N.archive_entry_acl_count(e, c[:ARCHIVE_ENTRY_ACL_TYPE_ACCESS]) == 5
    assert is_binary(N.archive_entry_acl_to_text(e, 0))
    assert is_binary(N.archive_entry_acl_to_text_w(e, 0))
    N.archive_entry_acl_reset(e, c[:ARCHIVE_ENTRY_ACL_TYPE_ACCESS])
    assert is_map(N.archive_entry_acl_next(e, c[:ARCHIVE_ENTRY_ACL_TYPE_ACCESS]))
    N.archive_entry_acl_clear(e)
    assert N.archive_entry_acl_types(e) == 0
  end

  test "matching supports path, owner, unmatched includes and owned lifetime" do
    m = N.archive_match_new()
    e = N.archive_entry_new()
    N.archive_match_include_pattern(m, "*.txt")
    N.archive_match_exclude_pattern(m, "secret*")
    N.archive_entry_set_pathname(e, "file.txt")
    assert N.archive_match_excluded(m, e) == 0
    N.archive_entry_set_pathname(e, "file.jpg")
    assert N.archive_match_path_excluded(m, e) == 1
    N.archive_entry_set_pathname(e, "secret.txt")
    assert N.archive_match_excluded(m, e) == 1
    N.archive_match_include_uid(m, 123)
    N.archive_entry_set_uid(e, 456)
    assert N.archive_match_owner_excluded(m, e) == 1
    other = N.archive_match_new()
    N.archive_match_include_pattern_w(other, "unused日本語")
    assert N.archive_match_path_unmatched_inclusions(other) == 1
    assert N.archive_match_path_unmatched_inclusions_next_w(other) == "unused日本語"

    assert {:error, :ArchiveEof} =
             N.safe_call(fn -> N.archive_match_path_unmatched_inclusions_next(other) end)

    N.archive_match_free(m)
    N.archive_match_free(other)
  end

  test "disk reading, disk writing and data blocks" do
    dir = Path.join(System.tmp_dir!(), "archive-native-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "file")
    File.write!(path, "hello")
    r = N.archive_read_disk_new()
    e = N.archive_entry_new()
    N.archive_read_disk_set_symlink_physical(r)

    if match?({:win32, _}, :os.type()) do
      assert {:error, _} = N.safe_call(fn -> N.archive_read_disk_set_standard_lookup(r) end)
      assert N.get_error_string(r) =~ "not available on Windows"
    else
      assert :ok = N.archive_read_disk_set_standard_lookup(r)
    end

    N.archive_read_disk_open(r, path)
    N.archive_read_next_header(r, e)
    assert N.archive_entry_size(e) == 5
    assert N.archive_read_disk_can_descend(r) == 0
    assert is_integer(N.archive_read_disk_current_filesystem(r))
    assert N.archive_read_disk_current_filesystem_is_remote(r) in [0, 1]
    N.archive_read_free(r)
    w = N.archive_write_disk_new()
    N.archive_write_disk_set_options(w, N.extractFlagToInt(:secure_nodotdot))
    N.archive_write_disk_set_standard_lookup(w)
    N.archive_entry_set_pathname(e, Path.join(dir, "copy"))
    N.archive_write_header(w, e)
    N.archive_write_data_block(w, "hello", 0)
    N.archive_write_finish_entry(w)
    N.archive_write_close(w)
    N.archive_write_free(w)
    assert File.read!(Path.join(dir, "copy")) == "hello"
  end

  test "rejects invalid resource types and embedded NUL strings" do
    assert {:error, :InvalidArchiveType} = N.safe_call(fn -> N.archive_format(make_ref()) end)
    e = N.archive_entry_new()

    assert {:error, :EmbeddedNul} =
             N.safe_call(fn -> N.archive_entry_set_pathname(e, <<"a", 0, "b">>) end)

    assert {:error, :argument_error} = N.safe_call(fn -> N.archive_entry_size("not a handle") end)
  end

  test "native configuration covers every direct format/filter support wrapper" do
    {bindings, _} = Code.eval_file(Path.expand("../priv/bindings.exs", __DIR__))

    for {name, _, 1, _} <- bindings,
        String.starts_with?(to_string(name), "archive_read_support_"),
        not String.ends_with?(to_string(name), "program") do
      r = N.archive_read_new()
      assert :ok = N.safe_call(fn -> apply(N, name, [r]) end, r)
      N.archive_read_free(r)
    end

    for {name, _, 1, _} <- bindings,
        String.starts_with?(to_string(name), "archive_write_set_format_") do
      w = N.archive_write_new()
      result = N.safe_call(fn -> apply(N, name, [w]) end, w)
      assert result == :ok or match?({:error, _}, result)
      N.archive_write_free(w)
    end

    for name <- [
          :archive_write_zip_set_compression_store,
          :archive_write_zip_set_compression_deflate,
          :archive_write_zip_set_compression_bzip2,
          :archive_write_zip_set_compression_lzma,
          :archive_write_zip_set_compression_xz,
          :archive_write_zip_set_compression_zstd
        ] do
      w = N.archive_write_new()
      N.archive_write_set_format_zip(w)
      result = N.safe_call(fn -> apply(N, name, [w]) end, w)
      assert result == :ok or match?({:error, _}, result)
      N.archive_write_free(w)
    end
  end

  test "link resolver clones inputs and owns returned handles" do
    r = N.archive_entry_linkresolver_new()
    N.archive_entry_linkresolver_set_strategy(r, N.archiveFormatToInt(:tar))
    first = N.archive_entry_new()
    N.archive_entry_set_pathname(first, "a")
    N.archive_entry_set_nlink(first, 2)
    N.archive_entry_set_ino(first, 42)
    N.archive_entry_set_dev(first, 1)
    N.archive_entry_set_size(first, 3)
    %{entry: out, spare: nil} = N.archive_entry_linkify(r, first)
    assert N.archive_entry_pathname(out) == "a"
    N.archive_entry_free(out)
    second = N.archive_entry_clone(first)
    N.archive_entry_set_pathname(second, "b")
    %{entry: out, spare: nil} = N.archive_entry_linkify(r, second)
    assert N.archive_entry_hardlink(out) == "a"
    assert N.archive_entry_size(out) == 0
    assert N.archive_entry_size(second) == 3
    N.archive_entry_free(out)
    assert %{entry: nil, spare: nil} = N.archive_entry_linkify(r, nil)
    assert %{entry: nil} = N.archive_entry_partial_links(r)
    N.archive_entry_linkresolver_free(r)
    assert :ok = N.archive_entry_linkresolver_free(r)
  end

  test "disk matcher is retained and explicit free rejects further use" do
    dir = Path.join(System.tmp_dir!(), "archive-matcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "file"), "hello")
    reader = N.archive_read_disk_new()
    matcher = N.archive_match_new()
    N.archive_match_include_pattern(matcher, "*")
    N.archive_read_disk_set_matching(reader, matcher)
    N.archive_read_disk_open(reader, dir)
    N.archive_match_free(matcher)
    entry = N.archive_entry_new()

    assert {:error, :MatcherClosed} =
             N.safe_call(fn -> N.archive_read_next_header(reader, entry) end)

    N.archive_read_free(reader)

    assert {:error, :InvalidArchiveType} =
             N.safe_call(fn -> N.archive_filter_count(N.archive_match_new()) end)

    assert {:error, :InvalidReaderType} =
             N.safe_call(fn -> N.archive_read_data(N.archive_write_new(), 1) end)

    assert {:error, :InvalidWriterType} =
             N.safe_call(fn -> N.archive_write_data(N.archive_read_new(), "x") end)

    assert {:error, :InvalidMatcherType} =
             N.safe_call(fn -> N.archive_match_include_pattern(N.archive_read_new(), "*") end)
  end
end
