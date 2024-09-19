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
  });
  const ArchiveError = error{ ArchiveFailed, ArchiveRetry, ArchiveWarn, ArchiveFatal, ArchiveEof };
  const CAllocError = error{ archiveEntry, archive };
  const beam = @import("beam");
  const enif = @import("erl_nif");
  const root = @import("root");

  pub const ArchiveResource = beam.Resource(*c.archive, root, .{ .Callbacks = ArchiveResourceCallbacks });
  pub const ArchiveEntryResource = beam.Resource(*c.archive_entry, root, .{ .Callbacks = ArchiveEntryResourceCallbacks });

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
