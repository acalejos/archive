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
        resources: [:ArchiveReaderResource, :ArchiveWriterResource, :ArchiveEntryResource]
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

  As long as you use the `ArchiveReaderResource` and `ArchiveEntryResource` reference types, they will
  be managed and garbage-collected by this module once created.

  Most functions in this module may raise `ErlangError` on failure. You should invoke **most** of
  these functions using `Archive.Nif.safe_call/2` to catch the errors and return them as `:ok` or
  an `{:error, reason}` tuple

  ## `libarchive` APIs

  `libarchive` distinguishes the following APIs:

  <!-- tabs-open -->
  ### `archive_read`
  > #### Reading an Archive {: .info}
  >
  > Although `Archive`'s high-level API takes care of all of the resource management for you, it can still be useful to understand how it works:
  >   1) Create new archive reader object
  >   2) Update any global reader properties as appropriate. These properties determine supported compressions, formats, etc.
  >   3) Open the archive
  >   4) Repeatedly call archive_read_next_header to get information about
  >       successive archive entries.  Call archive_read_data to extract
  >      data for entries of interest.
  >   5) Cleanup archive reader object

  ### `archive-write`
  > #### Creating an Archive {: .info}
  > To create an archive:
  >   1) Ask archive_write_new for an archive writer object.
  >   2) Set any global properties.  In particular, you should set
  >      the compression and format to use.
  >   3) Call archive_write_open to open the file (most people
  >       will use archive_write_open_file or archive_write_open_fd,
  >       which provide convenient canned I/O callbacks for you).
  >   4) For each entry:
  >      - construct an appropriate struct archive_entry structure
  >      - archive_write_header to write the header
  >      - archive_write_data to write the entry data
  >   5) archive_write_close to close the output
  >   6) archive_write_free to cleanup the writer and release resources

  ### `archive_write_disk`
  > #### Writing to Disk {: .info}
  To create objects on disk:
  >   1) Ask archive_write_disk_new for a new archive_write_disk object.
  >   2) Set any global properties.  In particular, you probably
  >      want to set the options.
  >   3) For each entry:
  >      - construct an appropriate struct archive_entry structure
  >      - archive_write_header to create the file/dir/etc on disk
  >      - archive_write_data to write the entry data
  >   4) archive_write_free to cleanup the writer and release resources
  >s
  > In particular, you can use this in conjunction with archive_read()
  > to pull entries out of an archive and create them on disk.
  <!-- tabs-close -->

  It also has `archive_read_extract` functions that combine reading with writing to disk.
  """
  require Logger
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

  pub const ArchiveReaderResource = beam.Resource(*c.archive, root, .{ .Callbacks = ArchiveReaderResourceCallbacks });
  pub const ArchiveWriterResource = beam.Resource(*c.archive, root, .{ .Callbacks = ArchiveWriterResourceCallbacks });
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

  pub const ArchiveFormat = enum(c_int) {
      cpio = c.ARCHIVE_FORMAT_CPIO,
      cpio_posix = c.ARCHIVE_FORMAT_CPIO_POSIX,
      cpio_bin_le = c.ARCHIVE_FORMAT_CPIO_BIN_LE,
      cpio_bin_be = c.ARCHIVE_FORMAT_CPIO_BIN_BE,
      cpio_svr4_nocrc = c.ARCHIVE_FORMAT_CPIO_SVR4_NOCRC,
      cpio_svr4_crc = c.ARCHIVE_FORMAT_CPIO_SVR4_CRC,
      cpio_afio_large = c.ARCHIVE_FORMAT_CPIO_AFIO_LARGE,
      cpio_pwb = c.ARCHIVE_FORMAT_CPIO_PWB,
      shar = c.ARCHIVE_FORMAT_SHAR,
      shar_base = c.ARCHIVE_FORMAT_SHAR_BASE,
      shar_dump = c.ARCHIVE_FORMAT_SHAR_DUMP,
      tar = c.ARCHIVE_FORMAT_TAR,
      tar_ustar = c.ARCHIVE_FORMAT_TAR_USTAR,
      tar_pax_interchange = c.ARCHIVE_FORMAT_TAR_PAX_INTERCHANGE,
      tar_pax_restricted = c.ARCHIVE_FORMAT_TAR_PAX_RESTRICTED,
      tar_gnutar = c.ARCHIVE_FORMAT_TAR_GNUTAR,
      iso9660 = c.ARCHIVE_FORMAT_ISO9660,
      iso9660_rockridge = c.ARCHIVE_FORMAT_ISO9660_ROCKRIDGE,
      zip = c.ARCHIVE_FORMAT_ZIP,
      empty = c.ARCHIVE_FORMAT_EMPTY,
      ar = c.ARCHIVE_FORMAT_AR,
      ar_gnu = c.ARCHIVE_FORMAT_AR_GNU,
      ar_bsd = c.ARCHIVE_FORMAT_AR_BSD,
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

  pub fn isSubFormatOf(self: ArchiveFormat, parent: ArchiveFormat) bool {
      return (@intFromEnum(self) & c.ARCHIVE_FORMAT_BASE_MASK) == @intFromEnum(parent);
  }

  pub const ExtractFlag = enum(c_int) {
      owner = c.ARCHIVE_EXTRACT_OWNER,
      perm = c.ARCHIVE_EXTRACT_PERM,
      time = c.ARCHIVE_EXTRACT_TIME,
      no_overwrite = c.ARCHIVE_EXTRACT_NO_OVERWRITE,
      unlink = c.ARCHIVE_EXTRACT_UNLINK,
      acl = c.ARCHIVE_EXTRACT_ACL,
      fflags = c.ARCHIVE_EXTRACT_FFLAGS,
      xattr = c.ARCHIVE_EXTRACT_XATTR,
      secure_symlinks = c.ARCHIVE_EXTRACT_SECURE_SYMLINKS,
      secure_nodotdot = c.ARCHIVE_EXTRACT_SECURE_NODOTDOT,
      no_autodir = c.ARCHIVE_EXTRACT_NO_AUTODIR,
      no_overwrite_newer = c.ARCHIVE_EXTRACT_NO_OVERWRITE_NEWER,
      sparse = c.ARCHIVE_EXTRACT_SPARSE,
      mac_metadata = c.ARCHIVE_EXTRACT_MAC_METADATA,
      no_hfs_compression = c.ARCHIVE_EXTRACT_NO_HFS_COMPRESSION,
      hfs_compression_forced = c.ARCHIVE_EXTRACT_HFS_COMPRESSION_FORCED,
      secure_noabsolutepaths = c.ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS,
      clear_nochange_fflags = c.ARCHIVE_EXTRACT_CLEAR_NOCHANGE_FFLAGS,
      safe_writes = c.ARCHIVE_EXTRACT_SAFE_WRITES,
  };

  const ExtractFlagDocs = struct {
      flag: ExtractFlag,
      default_doc: []const u8,
  };

  const extractFlagDocumentation = [_]ExtractFlagDocs{
      .{ .flag = .owner, .default_doc = "Do not try to set owner/group." },
      .{ .flag = .perm, .default_doc = "Do obey umask, do not restore SUID/SGID/SVTX bits." },
      .{ .flag = .time, .default_doc = "Do not restore mtime/atime." },
      .{ .flag = .no_overwrite, .default_doc = "Replace existing files." },
      .{ .flag = .unlink, .default_doc = "Try create first, unlink only if create fails with EEXIST." },
      .{ .flag = .acl, .default_doc = "Do not restore ACLs." },
      .{ .flag = .fflags, .default_doc = "Do not restore fflags." },
      .{ .flag = .xattr, .default_doc = "Do not restore xattrs." },
      .{ .flag = .secure_symlinks, .default_doc = "Do not try to guard against extracts redirected by symlinks. Note: With ARCHIVE_EXTRACT_UNLINK, will remove any intermediate symlink." },
      .{ .flag = .secure_nodotdot, .default_doc = "Do not reject entries with '..' as path elements." },
      .{ .flag = .no_autodir, .default_doc = "Create parent directories as needed." },
      .{ .flag = .no_overwrite_newer, .default_doc = "Overwrite files, even if one on disk is newer." },
      .{ .flag = .sparse, .default_doc = "Detect blocks of 0 and write holes instead." },
      .{ .flag = .mac_metadata, .default_doc = "Do not restore Mac extended metadata. This has no effect except on Mac OS." },
      .{ .flag = .no_hfs_compression, .default_doc = "Use HFS+ compression if it was compressed. This has no effect except on Mac OS v10.6 or later." },
      .{ .flag = .hfs_compression_forced, .default_doc = "Do not use HFS+ compression if it was not compressed. This has no effect except on Mac OS v10.6 or later." },
      .{ .flag = .secure_noabsolutepaths, .default_doc = "Do not reject entries with absolute paths" },
      .{ .flag = .clear_nochange_fflags, .default_doc = "Do not clear no-change flags when unlinking object" },
      .{ .flag = .safe_writes, .default_doc = "Do not extract atomically (using rename)" },
  };

  pub const Allow = enum {
      Read,
      Write,
      ReadWrite,
  };

  pub const ArchiveFormatInfo = struct {
      format: ArchiveFormat,
      allow: Allow,
  };

  pub const ArchiveFilterInfo = struct {
      filter: ArchiveFilter,
      allow: Allow,
  };

  pub const archive_format_info = [_]ArchiveFormatInfo{
      .{ .format = .cpio, .allow = .ReadWrite },
      .{ .format = .cpio_posix, .allow = .Write },
      .{ .format = .cpio_bin_le, .allow = .Write },
      .{ .format = .cpio_bin_be, .allow = .Write },
      .{ .format = .cpio_svr4_nocrc, .allow = .Write },
      .{ .format = .cpio_svr4_crc, .allow = .Write },
      .{ .format = .cpio_afio_large, .allow = .Write },
      .{ .format = .cpio_pwb, .allow = .Write },
      .{ .format = .shar, .allow = .Write },
      .{ .format = .shar_base, .allow = .Write },
      .{ .format = .shar_dump, .allow = .Write },
      .{ .format = .tar, .allow = .ReadWrite },
      .{ .format = .tar_ustar, .allow = .Write },
      .{ .format = .tar_pax_interchange, .allow = .Write },
      .{ .format = .tar_pax_restricted, .allow = .Write },
      .{ .format = .tar_gnutar, .allow = .Write },
      .{ .format = .iso9660, .allow = .ReadWrite },
      .{ .format = .iso9660_rockridge, .allow = .Read },
      .{ .format = .zip, .allow = .ReadWrite },
      .{ .format = .empty, .allow = .Read },
      .{ .format = .ar, .allow = .Read },
      .{ .format = .ar_gnu, .allow = .Read },
      .{ .format = .ar_bsd, .allow = .Read },
      .{ .format = .mtree, .allow = .ReadWrite },
      .{ .format = .raw, .allow = .ReadWrite },
      .{ .format = .xar, .allow = .ReadWrite },
      .{ .format = .lha, .allow = .Read },
      .{ .format = .cab, .allow = .Read },
      .{ .format = .rar, .allow = .Read },
      .{ .format = .sevenz, .allow = .ReadWrite },
      .{ .format = .warc, .allow = .ReadWrite },
      .{ .format = .rar_v5, .allow = .Read },
  };

  pub const archive_filter_info = [_]ArchiveFilterInfo{
      .{ .filter = .none, .allow = .ReadWrite },
      .{ .filter = .gzip, .allow = .ReadWrite },
      .{ .filter = .bzip2, .allow = .ReadWrite },
      .{ .filter = .compress, .allow = .ReadWrite },
      .{ .filter = .lzma, .allow = .ReadWrite },
      .{ .filter = .xz, .allow = .ReadWrite },
      .{ .filter = .uu, .allow = .ReadWrite },
      .{ .filter = .lzip, .allow = .ReadWrite },
      .{ .filter = .lrzip, .allow = .ReadWrite },
      .{ .filter = .lzop, .allow = .ReadWrite },
      .{ .filter = .grzip, .allow = .ReadWrite },
      .{ .filter = .lz4, .allow = .ReadWrite },
      .{ .filter = .zstd, .allow = .ReadWrite },
      .{ .filter = .rpm, .allow = .Read },
  };

  fn TableNames(comptime table: anytype, comptime getFormat: fn (info: @TypeOf(table[0])) []const u8, comptime condition: fn (info: @TypeOf(table[0])) bool) []const []const u8 {
      @setEvalBranchQuota(10000); // Increase if needed for larger arrays

      return comptime blk: {
          var result: []const []const u8 = &[_][]const u8{};
          for (table) |info| {
              if (condition(info)) {
                  result = result ++ [_][]const u8{getFormat(info)};
              }
          }
          break :blk result;
      };
  }

  pub const format_readable_names = TableNames(archive_format_info, struct {
      fn getFormat(info: @TypeOf(archive_format_info[0])) []const u8 {
          return @tagName(info.format);
      }
  }.getFormat, struct {
      fn isReadable(info: @TypeOf(archive_format_info[0])) bool {
          return info.allow == .Read or info.allow == .ReadWrite;
      }
  }.isReadable);

  pub const format_writable_names = TableNames(archive_format_info, struct {
      fn getFormat(info: @TypeOf(archive_format_info[0])) []const u8 {
          return @tagName(info.format);
      }
  }.getFormat, struct {
      fn isWritable(info: @TypeOf(archive_format_info[0])) bool {
          return info.allow == .Write or info.allow == .ReadWrite;
      }
  }.isWritable);

  pub const filter_readable_names = TableNames(archive_filter_info, struct {
      fn getFormat(info: @TypeOf(archive_filter_info[0])) []const u8 {
          return @tagName(info.filter);
      }
  }.getFormat, struct {
      fn isReadable(info: @TypeOf(archive_filter_info[0])) bool {
          return info.allow == .Read or info.allow == .ReadWrite;
      }
  }.isReadable);

  pub const filter_writable_names = TableNames(archive_filter_info, struct {
      fn getFormat(info: @TypeOf(archive_filter_info[0])) []const u8 {
          return @tagName(info.filter);
      }
  }.getFormat, struct {
      fn isWritable(info: @TypeOf(archive_filter_info[0])) bool {
          return info.allow == .Write or info.allow == .ReadWrite;
      }
  }.isWritable);

  pub fn listReadableFormats() []const []const u8 {
      return format_readable_names;
  }

  pub fn listReadableFilters() []const []const u8 {
      return filter_readable_names;
  }

  pub fn listWritableFormats() []const []const u8 {
      return format_writable_names;
  }

  pub fn listWritableFilters() []const []const u8 {
      return filter_writable_names;
  }

  pub const ArchiveReaderResourceCallbacks = struct {
      pub fn dtor(a: **c.archive) void {
          _ = c.archive_read_free(a.*);
      }
  };

  pub const ArchiveWriterResourceCallbacks = struct {
      pub fn dtor(a: **c.archive) void {
          _ = c.archive_write_free(a.*);
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

  pub const CustomStat = struct {
      inode: i64,
      size: i64,
      mode: u16,
      kind: FileKind,
      atime_sec: i64,
      atime_nsec: i64,
      mtime_sec: i64,
      mtime_nsec: i64,
      ctime_sec: i64,
      ctime_nsec: i64,
      nlinks: c_uint,
      devmajor: c_int,
      devminor: c_int,
      gid: i64,
      uid: i64,
  };

  pub fn archive_entry_copy_stat(e: ArchiveEntryResource, stat: CustomStat) void {
      std.debug.print("My struct: {any}\n", .{stat});
      c.archive_entry_set_ino(e.unpack(), stat.inode);
      c.archive_entry_set_size(e.unpack(), stat.size);
      c.archive_entry_set_mode(e.unpack(), stat.mode);

      if (stat.kind != .unknown) {
          c.archive_entry_set_filetype(e.unpack(), @intFromEnum(stat.kind));
      }

      c.archive_entry_set_atime(e.unpack(), stat.atime_sec, stat.atime_nsec);
      c.archive_entry_set_mtime(e.unpack(), stat.mtime_sec, stat.mtime_nsec);
      c.archive_entry_set_ctime(e.unpack(), stat.ctime_sec, stat.ctime_nsec);

      c.archive_entry_set_nlink(e.unpack(), stat.nlinks);
      c.archive_entry_set_devmajor(e.unpack(), stat.devmajor);
      c.archive_entry_set_devminor(e.unpack(), stat.devminor);
      c.archive_entry_set_gid(e.unpack(), stat.gid);
      c.archive_entry_set_uid(e.unpack(), stat.uid);
  }

  fn getFileKind(mode: c_uint) FileKind {
      return std.meta.intToEnum(FileKind, mode & c.S_IFMT) catch .unknown;
  }
  pub fn archive_entry_stat(e: ArchiveEntryResource) !CustomStat {
      const c_stat = c.archive_entry_stat(e.unpack());
      if (c_stat == null) {
          return error.StatError;
      }
      const stat = c_stat.*;

      return CustomStat{
          .inode = @as(i64, @bitCast(stat.st_ino)),
          .size = @as(i64, @bitCast(stat.st_size)),
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
      };
  }

  pub fn archiveFilterToInt(filter: ArchiveFilter) c_int {
      return @intFromEnum(filter);
  }

  pub fn archiveFilterToAtom(filter: i32) ArchiveFilter {
      return @enumFromInt(filter);
  }

  pub fn archiveFormatToInt(format: ArchiveFormat) c_int {
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

  pub fn archive_read_new() !ArchiveReaderResource {
      const a: ?*c.archive = c.archive_read_new();
      return if (a) |non_null_a|
          ArchiveReaderResource.create(non_null_a, .{})
      else
          error.archiveEntry;
  }

  pub fn archive_write_new() !ArchiveWriterResource {
      const a: ?*c.archive = c.archive_write_new();
      return if (a) |non_null_a|
          ArchiveWriterResource.create(non_null_a, .{})
      else
          error.archiveEntry;
  }

  pub fn archive_read_support_filter_all(a: ArchiveReaderResource) !void {
      try checkArchiveResult(c.archive_read_support_filter_all(a.unpack()));
  }

  pub fn archive_read_support_format_all(a: ArchiveReaderResource) !void {
      try checkArchiveResult(c.archive_read_support_format_all(a.unpack()));
  }

  pub fn archive_read_open_filename(a: ArchiveReaderResource, filename: []u8, block_size: usize) !void {
      //   Have to manually null-terminate this for the C API
      // Zig's []u8 hold length information, so they aren't necessarily null-terminated
      var slice = try beam.allocator.alloc(u8, filename.len + 1);
      defer beam.allocator.free(slice);
      @memcpy(slice[0..filename.len], filename);
      slice[filename.len] = 0;
      const result = c.archive_read_open_filename(a.unpack(), slice.ptr, block_size);
      try checkArchiveResult(result);
  }

  pub fn archive_write_open_filename(a: ArchiveWriterResource, filename: []u8) !void {
      var slice = try beam.allocator.alloc(u8, filename.len + 1);
      defer beam.allocator.free(slice);
      @memcpy(slice[0..filename.len], filename);
      slice[filename.len] = 0;
      const result = c.archive_write_open_filename(a.unpack(), slice.ptr);
      try checkArchiveResult(result);
  }

  pub fn archive_read_open_memory(a: ArchiveReaderResource, buf: []const u8) !void {
      const result = c.archive_read_open_memory(a.unpack(), buf.ptr, buf.len);
      try checkArchiveResult(result);
  }

  pub fn archive_format_name(a: ArchiveReaderResource) [*c]u8 {
      return @constCast(c.archive_format_name(a.unpack()));
  }

  pub fn archive_file_count(a: ArchiveReaderResource) i32 {
      return c.archive_file_count(a.unpack());
  }

  pub fn archive_entry_new() !ArchiveEntryResource {
      const e: ?*c.archive_entry = c.archive_entry_new();
      return if (e) |non_null_e|
          ArchiveEntryResource.create(non_null_e, .{})
      else
          error.archiveEntry;
  }

  pub fn archive_read_next_header(a: ArchiveReaderResource, e: ArchiveEntryResource) !void {
      try checkArchiveResult(c.archive_read_next_header2(a.unpack(), e.unpack()));
  }

  pub fn archive_write_header(a: ArchiveWriterResource, e: ArchiveEntryResource) !void {
      try checkArchiveResult(c.archive_write_header(a.unpack(), e.unpack()));
  }
  pub fn archive_entry_pathname(e: ArchiveEntryResource) [*c]u8 {
      return @constCast(c.archive_entry_pathname(e.unpack()));
  }

  pub fn archive_entry_set_pathname(e: ArchiveEntryResource, pathname: [*c]const u8) void {
      return c.archive_entry_set_pathname(e.unpack(), pathname);
  }

  fn getArchive(term: beam.term) !*c.archive {
      if (beam.get(ArchiveReaderResource, term, .{})) |reader| {
          return reader.unpack();
      } else |_| {
          if (beam.get(ArchiveWriterResource, term, .{})) |writer| {
              return writer.unpack();
          } else |_| {
              return error.InvalidArchiveType;
          }
      }
  }

  pub fn archive_error_string(term: beam.term) ![*c]u8 {
      const archive = try getArchive(term);
      return @constCast(c.archive_error_string(archive));
  }

  pub fn archive_clear_error(term: beam.term) !void {
      const archive = try getArchive(term);
      c.archive_clear_error(archive);
  }

  pub fn archive_format(a: ArchiveReaderResource) i32 {
      return c.archive_format(a.unpack());
  }

  pub fn archive_entry_size(e: ArchiveEntryResource) i64 {
      return c.archive_entry_size(e.unpack());
  }

  pub fn archive_read_close(a: ArchiveReaderResource) !void {
      try checkArchiveResult(c.archive_read_close(a.unpack()));
  }

  pub fn archive_write_close(a: ArchiveWriterResource) !void {
      try checkArchiveResult(c.archive_write_close(a.unpack()));
  }

  pub fn archive_read_support_format_raw(a: ArchiveReaderResource) !void {
      try checkArchiveResult(c.archive_read_support_format_raw(a.unpack()));
  }

  pub fn archive_read_support_compression_all(a: ArchiveReaderResource) !void {
      try checkArchiveResult(c.archive_read_support_compression_all(a.unpack()));
  }

  pub fn archive_read_data(a: ArchiveReaderResource, size: usize) !beam.term {
      const data = try beam.allocator.alloc(u8, size);
      defer beam.allocator.free(data);

      const num_read: isize = c.archive_read_data(a.unpack(), data.ptr, size);
      if (size != num_read) {
          return CAllocError.archive;
      } else {
          return beam.make(data, .{});
      }
  }

  pub fn archive_read_support_format_by_code(a: ArchiveReaderResource, code: c_int) !void {
      try checkArchiveResult(c.archive_read_support_format_by_code(a.unpack(), code));
  }

  pub fn archive_read_support_filter_by_code(a: ArchiveReaderResource, code: c_int) !void {
      try checkArchiveResult(c.archive_read_support_filter_by_code(a.unpack(), code));
  }

  pub fn archive_read_format_capabilities(a: ArchiveReaderResource) i32 {
      return c.archive_read_format_capabilities(a.unpack());
  }

  pub fn archive_write_add_filter(a: ArchiveWriterResource, code: c_int) !void {
      try checkArchiveResult(c.archive_write_add_filter(a.unpack(), code));
  }

  pub fn archive_write_set_format(a: ArchiveWriterResource, code: c_int) !void {
      try checkArchiveResult(c.archive_write_set_format(a.unpack(), code));
  }

  pub fn archive_entry_clear(e: ArchiveEntryResource) !void {
      const orig = e.unpack();
      const cleared = c.archive_entry_clear(orig) orelse return error.ArchiveEntryClearFailed;
      e.update(cleared);
  }

  pub fn archive_read_refresh(a: ArchiveReaderResource) !void {
      const orig = a.unpack();
      _ = c.archive_read_free(orig);
      const new_archive = c.archive_read_new() orelse return error.ArchiveCreationFailed;
      a.update(new_archive);
  }

  pub fn archive_write_refresh(a: ArchiveWriterResource) !void {
      const orig = a.unpack();
      _ = c.archive_write_free(orig);
      const new_archive = c.archive_write_new() orelse return error.ArchiveCreationFailed;
      a.update(new_archive);
  }

  pub fn archive_compression(a: ArchiveReaderResource) i32 {
      return c.archive_compression(a.unpack());
  }

  pub fn archive_compression_name(a: ArchiveReaderResource) [*c]u8 {
      return @constCast(c.archive_compression_name(a.unpack()));
  }

  pub fn archive_version_string() [*c]u8 {
      return @constCast(c.archive_version_string());
  }

  pub fn archive_version_details() [*c]u8 {
      return @constCast(c.archive_version_details());
  }
  pub fn archive_zlib_version() [*c]u8 {
      return @constCast(c.archive_zlib_version());
  }
  pub fn archive_liblzma_version() [*c]u8 {
      return @constCast(c.archive_liblzma_version());
  }
  pub fn archive_bzlib_version() [*c]u8 {
      return @constCast(c.archive_bzlib_version());
  }
  pub fn archive_liblz4_version() [*c]u8 {
      return @constCast(c.archive_liblz4_version());
  }
  pub fn archive_libzstd_version() [*c]u8 {
      return @constCast(c.archive_libzstd_version());
  }
  pub fn archive_read_extract(a: ArchiveReaderResource, e: ArchiveEntryResource, flags: i32) !void {
      try checkArchiveResult(c.archive_read_extract(a.unpack(), e.unpack(), flags));
  }

  pub fn getExtractInfo() [extractFlagDocumentation.len]ExtractFlagDocs {
      return extractFlagDocumentation;
  }

  pub fn extractFlagToInt(f: ExtractFlag) i32 {
      return @intFromEnum(f);
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
          %{original: :ArchiveWarn} ->
            if error_string, do: Logger.info(error_string)
            :ok

          %{original: error} when error in @errors ->
            {:error, error_string || error}

          %{reason: reason} ->
            {:error, error_string || reason}

          %{message: message} ->
            {:error, error_string || message}
        end
    end
  end

  defmacro call(func) do
    quote do
      safe_call(fn -> unquote(func) end)
    end
  end

  defmacro call(func, ref) do
    quote do
      safe_call(fn -> unquote(func) end, unquote(ref))
    end
  end

  @doc false
  def unwrap!(:ok), do: :ok
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: raise(reason)
  def unwrap(_), do: raise("Bad value")

  def list_all(:formats, :read), do: listReadableFormats() |> Enum.map(&String.to_atom/1)
  def list_all(:filters, :read), do: listReadableFilters() |> Enum.map(&String.to_atom/1)
  def list_all(:formats, :write), do: listWritableFormats() |> Enum.map(&String.to_atom/1)
  def list_all(:filters, :write), do: listWritableFilters() |> Enum.map(&String.to_atom/1)

  def file_stat_to_zig_map(%File.Stat{} = stat) do
    %{
      inode: convert_integer(stat.inode),
      size: convert_integer(stat.size),
      mode: convert_integer(stat.mode),
      kind: convert_type(stat.type),
      atime_sec: extract_seconds(stat.atime),
      atime_nsec: extract_nanoseconds(stat.atime),
      mtime_sec: extract_seconds(stat.mtime),
      mtime_nsec: extract_nanoseconds(stat.mtime),
      ctime_sec: extract_seconds(stat.ctime),
      ctime_nsec: extract_nanoseconds(stat.ctime),
      nlinks: convert_integer(stat.links),
      devmajor: convert_integer(stat.major_device),
      devminor: convert_integer(stat.minor_device),
      gid: convert_integer(stat.gid),
      uid: convert_integer(stat.uid)
    }
  end

  defp convert_type(:device), do: :block_device
  defp convert_type(:directory), do: :directory
  defp convert_type(:regular), do: :file
  defp convert_type(:symlink), do: :sym_link
  defp convert_type(_), do: :unknown

  defp convert_integer(:undefined), do: 0
  defp convert_integer(value) when is_integer(value), do: value
  defp convert_integer(_), do: 0

  defp extract_seconds(:undefined), do: 0

  defp extract_seconds({{year, month, day}, {hour, minute, second}}) do
    :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}}) -
      62_167_219_200
  end

  defp extract_seconds(unix_timestamp) when is_integer(unix_timestamp), do: unix_timestamp
  defp extract_seconds(_), do: 0

  defp extract_nanoseconds(:undefined), do: 0
  # Calendar format doesn't include nanoseconds
  defp extract_nanoseconds({{_, _, _}, {_, _, _}}), do: 0
  # For integer timestamps, we don't have nanosecond precision
  defp extract_nanoseconds(_), do: 0

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

  defmacro __using__(_opts) do
    read_formats = list_all(:formats, :read)
    read_filters = list_all(:filters, :read)
    write_formats = list_all(:formats, :write)
    write_filters = list_all(:filters, :write)
    extract_info = getExtractInfo()

    quote do
      alias Archive.Nif
      import Archive.Nif, only: [unwrap!: 1, call: 1, call: 2, safe_call: 2, safe_call: 1]
      @read_formats unquote(read_formats)
      @read_filters unquote(read_filters)
      @write_formats unquote(write_formats)
      @write_filters unquote(write_filters)
      @extract_info unquote(Macro.escape(extract_info))
    end
  end
end
