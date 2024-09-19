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
  use Archive.Setup

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
      const result = c.archive_read_open_filename(a.unpack(), filename.ptr, block_size);
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
            archive_error_string(ref)
          end

        case e do
          %{original: error} when error in @errors ->
            {:error, error_string || error}

          _ ->
            {:error, error_string || e.reason}
        end
    end
  end
end
