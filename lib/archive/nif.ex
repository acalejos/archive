defmodule Archive.Setup do
  @moduledoc false
  @ext (case :os.type() do
          {:win32, _} -> ".dll"
          {:unix, :darwin} -> ".dylib"
          {:unix, _} -> ".so"
        end)

  @base_path "#{:code.priv_dir(:archive)}/#{Mix.target()}"
  @include_path "#{@base_path}/include/"
  @link_path "#{@base_path}/lib/libarchive#{@ext}"

  defmacro __using__(_opts) do
    quote do
      use Zig,
        otp_app: :archive,
        c: [
          include_dirs: [unquote(@include_path)],
          link_lib: unquote(@link_path)
        ],
        resources: [:ArchiveResource, :ArchiveEntryResource]
    end
  end
end

defmodule Archive.Nif do
  @moduledoc """
  > #### Proceed With Caution {: .error}
  >
  > The `Archive.Nif` module contains the functions that directly interact with `libarchive`.
  > It is generally discouraged to interact with this library directly. If you find you need
  > functionality not supported in the higher-level APIs, consider opening an issue first
  > if the feature would be generally applicable or desireable.

  `Archive.Nif` provides direct `Elixir` bindings to the `libarchive` C API. Most of the functions
  in this module are 1-to-1 mappings to the C API equivalent functions.

  These functions work directly with references, rather than `Archive` or `Archive.Entry` structs.

  As long as you use the `ArchiveResource` and `ArchiveEntryResource` reference types, they will
  be managed and garbage-collected by this module once created.

  Most functions in this module may raise `ErlangError` on failure. You should invoke **most** of
  these functions using `Archive.Nif.safe_call/2` to catch the errors and return them as `:ok` or
  an `{:error, reason}` tuple
  """
  use Archive.Setup
  import Bitwise

  ~Z"""
  const c = @cImport({
      @cInclude("archive.h");
      @cInclude("archive_entry.h");
      @cInclude("sys/stat.h");
      @cInclude("time.h");
  });
  const ArchiveError = error{ ArchiveFailed, ArchiveRetry, ArchiveWarn, ArchiveFatal, ArchiveEof };
  const CAllocError = error{ archiveEntry, archive };
  const std = @import("std");
  const beam = @import("beam");
  const enif = @import("erl_nif");
  const root = @import("root");

  pub const ArchiveResource = beam.Resource(*c.archive, root, .{ .Callbacks = ArchiveResourceCallbacks });
  pub const ArchiveEntryResource = beam.Resource(*c.archive_entry, root, .{ .Callbacks = ArchiveEntryResourceCallbacks });

  pub const ArchiveFilter = enum(c_int) {
      none = c.ARCHIVE_FILTER_NONE,
      gzip = c.ARCHIVE_FILTER_GZIP,
      bzip2 = c.ARCHIVE_FILTER_BZIP2,
      compress = c.ARCHIVE_FILTER_COMPRESS,
      program = c.ARCHIVE_FILTER_PROGRAM,
      lzma = c.ARCHIVE_FILTER_LZMA,
      xz = c.ARCHIVE_FILTER_XZ,
      uu = c.ARCHIVE_FILTER_UU,
      rpm = c.ARCHIVE_FILTER_RPM,
      lzip = c.ARCHIVE_FILTER_LZIP,
      lrzip = c.ARCHIVE_FILTER_LRZIP,
      lzop = c.ARCHIVE_FILTER_LZOP,
      grzip = c.ARCHIVE_FILTER_GRZIP,
      lz4 = c.ARCHIVE_FILTER_LZ4,
      zstd = c.ARCHIVE_FILTER_ZSTD,
  };

  pub const ArchiveBaseFormat = enum(c_int) {
      base_mask = c.ARCHIVE_FORMAT_BASE_MASK,
      cpio = c.ARCHIVE_FORMAT_CPIO,
      shar = c.ARCHIVE_FORMAT_SHAR,
      tar = c.ARCHIVE_FORMAT_TAR,
      iso9660 = c.ARCHIVE_FORMAT_ISO9660,
      zip = c.ARCHIVE_FORMAT_ZIP,
      empty = c.ARCHIVE_FORMAT_EMPTY,
      ar = c.ARCHIVE_FORMAT_AR,
      mtree = c.ARCHIVE_FORMAT_MTREE,
      raw = c.ARCHIVE_FORMAT_RAW,
      xar = c.ARCHIVE_FORMAT_XAR,
      lha = c.ARCHIVE_FORMAT_LHA,
      cab = c.ARCHIVE_FORMAT_CAB,
      rar = c.ARCHIVE_FORMAT_RAR,
      sevenz = c.ARCHIVE_FORMAT_7ZIP,
      warc = c.ARCHIVE_FORMAT_WARC,
      rar_v5 = c.ARCHIVE_FORMAT_RAR_V5,
  };

  pub const ArchiveFormat = enum(c_int) {
      base_mask = @intFromEnum(ArchiveBaseFormat.base_mask),
      cpio = @intFromEnum(ArchiveBaseFormat.cpio),
      cpio_posix = @intFromEnum(ArchiveBaseFormat.cpio) | 1,
      cpio_bin_le = @intFromEnum(ArchiveBaseFormat.cpio) | 2,
      cpio_bin_be = @intFromEnum(ArchiveBaseFormat.cpio) | 3,
      cpio_svr4_nocrc = @intFromEnum(ArchiveBaseFormat.cpio) | 4,
      cpio_svr4_crc = @intFromEnum(ArchiveBaseFormat.cpio) | 5,
      cpio_afio_large = @intFromEnum(ArchiveBaseFormat.cpio) | 6,
      cpio_pwb = @intFromEnum(ArchiveBaseFormat.cpio) | 7,
      shar = @intFromEnum(ArchiveBaseFormat.shar),
      shar_base = @intFromEnum(ArchiveBaseFormat.shar) | 1,
      shar_dump = @intFromEnum(ArchiveBaseFormat.shar) | 2,
      tar = @intFromEnum(ArchiveBaseFormat.tar),
      tar_ustar = @intFromEnum(ArchiveBaseFormat.tar) | 1,
      tar_pax_interchange = @intFromEnum(ArchiveBaseFormat.tar) | 2,
      tar_pax_restricted = @intFromEnum(ArchiveBaseFormat.tar) | 3,
      tar_gnutar = @intFromEnum(ArchiveBaseFormat.tar) | 4,
      iso9660 = @intFromEnum(ArchiveBaseFormat.iso9660),
      iso9660_rockridge = @intFromEnum(ArchiveBaseFormat.iso9660) | 1,
      zip = @intFromEnum(ArchiveBaseFormat.zip),
      empty = @intFromEnum(ArchiveBaseFormat.empty),
      ar = @intFromEnum(ArchiveBaseFormat.ar),
      ar_gnu = @intFromEnum(ArchiveBaseFormat.ar) | 1,
      ar_bsd = @intFromEnum(ArchiveBaseFormat.ar) | 2,
      mtree = @intFromEnum(ArchiveBaseFormat.mtree),
      raw = @intFromEnum(ArchiveBaseFormat.raw),
      xar = @intFromEnum(ArchiveBaseFormat.xar),
      lha = @intFromEnum(ArchiveBaseFormat.lha),
      cab = @intFromEnum(ArchiveBaseFormat.cab),
      rar = @intFromEnum(ArchiveBaseFormat.rar),
      sevenz = @intFromEnum(ArchiveBaseFormat.sevenz),
      warc = @intFromEnum(ArchiveBaseFormat.warc),
      rar_v5 = @intFromEnum(ArchiveBaseFormat.rar_v5),
  };

  pub const ArchiveResourceCallbacks = struct {
      pub fn dtor(a: **c.archive) void {
          _ = c.archive_read_free(a.*);
      }
  };

  pub const ArchiveEntryResourceCallbacks = struct {
      pub fn dtor(a: **c.archive_entry) void {
          _ = c.archive_entry_free(a.*);
      }
  };

  const FileKind = enum(c_uint) {
      block_device = c.S_IFBLK,
      character_device = c.S_IFCHR,
      directory = c.S_IFDIR,
      named_pipe = c.S_IFIFO,
      sym_link = c.S_IFLNK,
      file = c.S_IFREG,
      unix_domain_socket = c.S_IFSOCK,
      unknown = 0,
  };

  const FileMode = enum(c_uint) {
      irwxu = c.S_IRWXU,
      irusr = c.S_IRUSR,
      iwusr = c.S_IWUSR,
      ixusr = c.S_IXUSR,
      irwxg = c.S_IRWXG,
      irgrp = c.S_IRGRP,
      iwgrp = c.S_IWGRP,
      ixgrp = c.S_IXGRP,
      irwxo = c.S_IRWXO,
      iroth = c.S_IROTH,
      iwoth = c.S_IWOTH,
      ixoth = c.S_IXOTH,
      isuid = c.S_ISUID,
      isgid = c.S_ISGID,
      isvtx = c.S_ISVTX,
  };

  pub fn archive_entry_stat(e: ArchiveEntryResource) beam.term {
      const c_stat = c.archive_entry_stat(e.unpack());
      if (c_stat == null) {
          return beam.make_error_pair("failed_to_get_stat", .{});
      }
      const stat = c_stat.*;

      return beam.make(.{
          .inode = stat.st_ino,
          .size = @as(u64, @bitCast(stat.st_size)),
          .mode = stat.st_mode,
          .kind = getFileKind(stat.st_mode),
          .atime_sec = stat.st_atimespec.tv_sec,
          .atime_nsec = stat.st_atimespec.tv_nsec,
          .mtime_sec = stat.st_mtimespec.tv_sec,
          .mtime_nsec = stat.st_mtimespec.tv_nsec,
          .ctime_sec = stat.st_ctimespec.tv_sec,
          .ctime_nsec = stat.st_ctimespec.tv_nsec,
          .nlinks = c.archive_entry_nlink(e.unpack()),
          .devmajor = c.archive_entry_devmajor(e.unpack()),
          .devminor = c.archive_entry_devminor(e.unpack()),
          .gid = c.archive_entry_gid(e.unpack()),
          .uid = c.archive_entry_uid(e.unpack()),
      }, .{});
  }

  fn getFileKind(mode: c_uint) FileKind {
      return std.meta.intToEnum(FileKind, mode & c.S_IFMT) catch .unknown;
  }

  pub fn archiveFilterToInt(filter: ArchiveFilter) i32 {
      return @intFromEnum(filter);
  }

  pub fn archiveFilterToAtom(filter: i32) ArchiveFilter {
      return @enumFromInt(filter);
  }

  pub fn archiveFormatToInt(format: ArchiveFormat) i32 {
      return @intFromEnum(format);
  }

  pub fn archiveFormatToAtom(format: i32) ArchiveFormat {
      return @enumFromInt(format);
  }

  fn checkArchiveResult(result: c_int) !void {
      switch (result) {
          c.ARCHIVE_OK => return,
          c.ARCHIVE_RETRY => return ArchiveError.ArchiveRetry,
          c.ARCHIVE_WARN => return ArchiveError.ArchiveWarn,
          c.ARCHIVE_FATAL => return ArchiveError.ArchiveFatal,
          c.ARCHIVE_EOF => return ArchiveError.ArchiveEof,
          else => return ArchiveError.ArchiveFailed,
      }
  }

  pub fn archive_read_new() !ArchiveResource {
      const a: ?*c.archive = c.archive_read_new();
      return if (a) |non_null_a|
          ArchiveResource.create(non_null_a, .{})
      else
          error.archiveEntry;
  }

  pub fn archive_read_support_filter_all(a: ArchiveResource) !void {
      try checkArchiveResult(c.archive_read_support_filter_all(a.unpack()));
  }

  pub fn archive_read_support_format_all(a: ArchiveResource) !void {
      try checkArchiveResult(c.archive_read_support_format_all(a.unpack()));
  }

  pub fn archive_read_open_filename(a: ArchiveResource, filename: []u8, block_size: usize) !void {
      //   Have to manually null-terminate this for the C API
      // Zig's []u8 hold length information, so they aren't necessarily null-terminated
      var slice = try beam.allocator.alloc(u8, filename.len + 1);
      defer beam.allocator.free(slice);
      @memcpy(slice[0..filename.len], filename);
      slice[filename.len] = 0;
      const result = c.archive_read_open_filename(a.unpack(), slice.ptr, block_size);
      try checkArchiveResult(result);
  }

  pub fn archive_read_open_memory(a: ArchiveResource, buf: []const u8) !void {
      const result = c.archive_read_open_memory(a.unpack(), buf.ptr, buf.len);
      try checkArchiveResult(result);
  }

  pub fn archive_format_name(a: ArchiveResource) [*c]u8 {
      return @constCast(c.archive_format_name(a.unpack()));
  }

  pub fn archive_file_count(a: ArchiveResource) i32 {
      return c.archive_file_count(a.unpack());
  }

  pub fn archive_entry_new() !ArchiveEntryResource {
      const e: ?*c.archive_entry = c.archive_entry_new();
      return if (e) |non_null_e|
          ArchiveEntryResource.create(non_null_e, .{})
      else
          error.archiveEntry;
  }

  pub fn archive_read_next_header(a: ArchiveResource, e: ArchiveEntryResource) !void {
      try checkArchiveResult(c.archive_read_next_header2(a.unpack(), e.unpack()));
  }
  pub fn archive_entry_pathname(e: ArchiveEntryResource) [*c]u8 {
      return @constCast(c.archive_entry_pathname(e.unpack()));
  }

  pub fn archive_error_string(a: ArchiveResource) [*c]u8 {
      return @constCast(c.archive_error_string(a.unpack()));
  }

  pub fn archive_clear_error(a: ArchiveResource) void {
      c.archive_clear_error(a.unpack());
  }

  pub fn archive_format(a: ArchiveResource) i32 {
      return c.archive_format(a.unpack());
  }

  pub fn archive_entry_size(e: ArchiveEntryResource) i64 {
      return c.archive_entry_size(e.unpack());
  }

  pub fn archive_read_close(a: ArchiveResource) !void {
      try checkArchiveResult(c.archive_read_close(a.unpack()));
  }

  pub fn archive_read_support_format_raw(a: ArchiveResource) !void {
      try checkArchiveResult(c.archive_read_support_format_raw(a.unpack()));
  }

  pub fn archive_read_support_compression_all(a: ArchiveResource) !void {
      try checkArchiveResult(c.archive_read_support_compression_all(a.unpack()));
  }

  pub fn archive_read_data(a: ArchiveResource, size: usize) ![]const u8 {
      const data = try beam.allocator.alloc(u8, size);
      defer beam.allocator.free(data);

      const num_read: isize = c.archive_read_data(a.unpack(), data.ptr, size);

      if (size != num_read) {
          return CAllocError.archive;
      } else {
          return data;
      }
  }

  pub fn archive_read_support_format_by_code(a: ArchiveResource, code: i32) !void {
      try checkArchiveResult(c.archive_read_support_format_by_code(a.unpack(), code));
  }

  pub fn archive_read_support_filter_by_code(a: ArchiveResource, code: i32) !void {
      try checkArchiveResult(c.archive_read_support_filter_by_code(a.unpack(), code));
  }

  pub fn archive_read_format_capabilities(a: ArchiveResource) i32 {
      return c.archive_read_format_capabilities(a.unpack());
  }
  """

  @errors [:ArchiveEof, :ArchiveFailed, :ArchiveWarn, :ArchiveFatal]

  def get_error_string(ref) when is_reference(ref) do
    err_string = archive_error_string(ref)

    err_string =
      unless is_nil(err_string) do
        err_string
        |> :binary.bin_to_list()
        |> Enum.filter(&(&1 < 128))
        |> List.to_string()
      end

    archive_clear_error(ref)

    err_string
  end

  def safe_call(fun, ref \\ nil) do
    try do
      case fun.() do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:ok, other}
      end
    rescue
      e in [ErlangError] ->
        error_string =
          if ref do
            get_error_string(ref)
          end

        case e do
          %{original: error} when error in @errors ->
            {:error, error_string || error}

          _ ->
            {:error, error_string || e.reason}
        end
    end
  end

  @doc false
  def unwrap!(:ok), do: :ok
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: raise(reason)
  def unwrap(_), do: raise("Bad value")

  @doc false
  def to_file_stat(zig_stat) do
    %File.Stat{
      access: get_access(zig_stat.mode),
      atime: convert_time(zig_stat.atime_sec, zig_stat.atime_nsec),
      ctime: convert_time(zig_stat.ctime_sec, zig_stat.ctime_nsec),
      gid: zig_stat.gid,
      inode: zig_stat.inode,
      links: zig_stat.nlinks,
      major_device: zig_stat.devmajor,
      minor_device: zig_stat.devminor,
      mode: zig_stat.mode,
      mtime: convert_time(zig_stat.mtime_sec, zig_stat.mtime_nsec),
      size: zig_stat.size,
      type: convert_kind(zig_stat.kind),
      uid: zig_stat.uid
    }
  end

  defp get_access(mode) do
    cond do
      (mode &&& 0o600) == 0o600 -> :read_write
      (mode &&& 0o400) == 0o400 -> :read
      (mode &&& 0o200) == 0o200 -> :write
      true -> :none
    end
  end

  defp convert_time(sec, nsec) do
    DateTime.from_unix!(sec, :second)
    |> DateTime.add(nsec, :nanosecond)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
  end

  defp convert_kind(:block_device), do: :device
  defp convert_kind(:character_device), do: :device
  defp convert_kind(:directory), do: :directory
  defp convert_kind(:named_pipe), do: :other
  defp convert_kind(:sym_link), do: :symlink
  defp convert_kind(:file), do: :regular
  defp convert_kind(:unix_domain_socket), do: :other
  defp convert_kind(:unknown), do: :other
end
