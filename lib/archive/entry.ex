defmodule Archive.Entry do
  @moduledoc """
  Metadata and an optional body for an archive member.

  Enumerated entries retain their native metadata, including links, ACLs,
  extended attributes, and sparse descriptors. Unread bodies can be forwarded
  directly into a writer or consumed in bounded chunks with `data_stream/2`.
  Consume them before advancing the archive; use `read_data/2` to retain a body.
  Create independent entries with `from_binary/3` or `from_file/2`.
  """
  use Archive.Nif
  alias Archive.Stream, as: ArchiveStream
  defstruct [:stat, :path, :data, :symlink, :hardlink, :source, :native]

  @type t :: %__MODULE__{
          stat: File.Stat.t(),
          path: String.t(),
          data: binary() | Enumerable.t() | nil,
          source: map() | nil,
          native: reference() | nil,
          symlink: String.t() | nil,
          hardlink: String.t() | nil
        }

  @doc "Creates an entry from fields."
  def new(fields \\ []), do: {:ok, struct!(__MODULE__, fields)}
  def new!(fields \\ []), do: new(fields) |> unwrap!()

  @doc "Creates a regular-file entry with an in-memory body. Options: `:mode` and `:mtime`."
  def from_binary(path, data, opts \\ []) when is_binary(path) and is_binary(data) do
    time = Keyword.get(opts, :mtime, 0)

    new!(
      path: path,
      data: data,
      stat: %File.Stat{
        size: byte_size(data),
        type: :regular,
        mode: Bitwise.bor(0o100000, Keyword.get(opts, :mode, 0o644)),
        atime: time,
        mtime: time,
        ctime: time,
        inode: 0,
        links: 1,
        uid: 0,
        gid: 0,
        major_device: 0,
        minor_device: 0
      }
    )
  end

  @doc "Creates a disk entry with a lazily streamed body, preserving symlinks. Options: `:path` and `:chunk_size`."
  def from_file(file, opts \\ []) do
    stat = File.lstat!(file, time: :posix)
    # Windows can report type :symlink with regular-file bits in File.Stat.mode.
    # Native archive formats use the mode bits to decide whether to emit a link.
    stat =
      if stat.type == :symlink,
        do: %{
          stat
          | mode: Bitwise.bor(Bitwise.band(stat.mode, 0o7777), Archive.Stat.file_kinds().sym_link)
        },
        else: stat

    data =
      if stat.type == :regular,
        do: File.stream!(file, Keyword.get(opts, :chunk_size, 65536)),
        else: nil

    symlink = if stat.type == :symlink, do: File.read_link!(file)

    new!(
      path: Keyword.get(opts, :path, Path.basename(file)),
      stat: stat,
      data: data,
      symlink: symlink
    )
  end

  @doc "Reads and retains the current entry body. The stream argument is retained for compatibility."
  def read_data(entry, stream \\ nil)
  def read_data(%__MODULE__{data: data} = entry, _) when is_binary(data), do: {:ok, entry}

  def read_data(%__MODULE__{} = entry, _) do
    try do
      data = entry |> data_stream() |> Enum.to_list() |> IO.iodata_to_binary()
      {:ok, %{entry | data: data}}
    rescue
      e in [Archive.Error, ErlangError] -> {:error, e}
    end
  end

  def read_data!(entry, stream \\ nil), do: read_data(entry, stream) |> unwrap!()

  @doc "Lazily reads the current body in chunks. Memory use is bounded by `chunk_size` (default 64 KiB)."
  def data_stream(entry, chunk_size \\ 65536)

  def data_stream(entry, size) when is_integer(size) and size > 0 do
    case entry do
      %{data: data} when is_binary(data) ->
        Stream.unfold(data, fn
          <<>> ->
            nil

          bytes ->
            n = min(size, byte_size(bytes))
            <<chunk::binary-size(n), rest::binary>> = bytes
            {chunk, rest}
        end)

      %{data: data} when not is_nil(data) ->
        data

      %{source: source} when not is_nil(source) ->
        Stream.unfold(source, fn source ->
          case ArchiveStream.checked(
                 fn ->
                   Nif.archive_read_data_current(source.reader, source.generation, size)
                 end,
                 source.reader
               ) do
            <<>> -> nil
            data -> {data, source}
          end
        end)

      %{stat: %{size: 0}} ->
        []

      %{native: native, path: path} when not is_nil(native) ->
        raise Archive.Error, reason: :BodyNotLoaded, action: "read entry", path: path

      _ ->
        raise ArgumentError, "entry has no body source; use from_binary/3 or from_file/2"
    end
  end

  def data_stream(_, _), do: raise(ArgumentError, "chunk_size must be a positive integer")

  defp assert_current!(source) do
    if Nif.archive_read_generation(source.reader) != source.generation do
      raise Archive.Error, reason: :EntryExpired, action: "read entry", path: source.path
    end
  end

  @doc "Extracts the current entry to disk. Uses the same options as `Archive.extract/2`."
  def extract(%__MODULE__{} = entry, _stream, opts \\ []) do
    with {:ok, opts} <- Archive.Utils.handle_extract_opts(opts),
         do: extract_prepared(entry, opts)
  end

  @doc false
  def extract_prepared(%__MODULE__{source: source, path: path}, opts) do
    assert_current!(source)
    cloned = Nif.archive_entry_clone(source.entry)

    try do
      target = extract_path!(path, opts)

      flags =
        if opts[:to],
          do:
            Bitwise.band(
              opts[:flags],
              Bitwise.bnot(Nif.extractFlagToInt(:secure_noabsolutepaths))
            ),
          else: opts[:flags]

      Nif.archive_entry_set_pathname_utf8(cloned, target)

      if hardlink = Nif.archive_entry_hardlink_utf8(cloned) do
        Nif.archive_entry_set_hardlink_utf8(cloned, extract_path!(hardlink, opts))
      end

      action = fn ->
        try do
          Nif.archive_read_extract_current(source.reader, source.generation, cloned, flags)
        rescue
          e in ErlangError -> {:error, Nif.get_error_string(source.reader) || e.original}
        end
      end

      action.()
    after
      Nif.archive_entry_free(cloned)
    end
  end

  defp extract_path!(path, opts) do
    target = (opts[:prefix] || "") <> path

    if Bitwise.band(opts[:flags], Nif.extractFlagToInt(:secure_noabsolutepaths)) != 0 &&
         Path.type(target) == :absolute,
       do: raise(Archive.Error, reason: "absolute entry path", path: target, action: "extract")

    if Bitwise.band(opts[:flags], Nif.extractFlagToInt(:secure_nodotdot)) != 0 &&
         ".." in Path.split(target),
       do:
         raise(Archive.Error,
           reason: "parent traversal in entry path",
           path: target,
           action: "extract"
         )

    if opts[:to], do: Path.expand(target, opts[:to]), else: target
  end

  @doc "Writes entry metadata to an initialized writer."
  def write_header(%__MODULE__{} = entry, %ArchiveStream{writer: %{ref: ref}, entry_ref: empty}) do
    metadata = entry.native || (entry.source && entry.source.entry)
    native = if metadata, do: Nif.archive_entry_clone(metadata), else: empty

    try do
      Nif.archive_entry_set_pathname_utf8(native, entry.path)
      original = if metadata, do: Nif.archive_entry_stat(native)
      previous = if original, do: Archive.Stat.to_file_stat(original)
      converted = Archive.Stat.file_stat_to_native_map(entry.stat)

      fields = [:ino, :size, :mode, :nlink, :uid, :gid, :dev, :rdev, :atim, :mtim, :ctim]

      stat = if original, do: Map.merge(original, Map.take(converted, fields)), else: converted

      # File.Stat's calendar timestamps omit nanoseconds. Keep the original
      # native precision for each timestamp the caller has not changed.
      stat =
        Enum.reduce(
          [{:atime, :atim}, {:mtime, :mtim}, {:ctime, :ctim}],
          stat,
          fn {field, key}, acc ->
            if previous && Map.fetch!(previous, field) == Map.fetch!(entry.stat, field) do
              Map.put(acc, key, Map.fetch!(original, key))
            else
              acc
            end
          end
        )

      stat =
        if previous && previous.major_device == entry.stat.major_device &&
             previous.minor_device == entry.stat.minor_device,
           do: Map.merge(stat, Map.take(original, [:dev, :rdev])),
           else: stat

      Nif.archive_entry_copy_stat(native, stat)

      if metadata do
        # Copying a C stat marks timestamps as present. Preserve absence when
        # unchanged, and birthtime which File.Stat does not expose.
        for {field, kind} <- [{:atime, :atime}, {:mtime, :mtime}, {:ctime, :ctime}],
            Map.fetch!(previous, field) == Map.fetch!(entry.stat, field),
            apply(Nif, String.to_existing_atom("archive_entry_#{kind}_is_set"), [metadata]) == 0 do
          apply(Nif, String.to_existing_atom("archive_entry_unset_#{kind}"), [native])
        end

        if Nif.archive_entry_birthtime_is_set(metadata) == 0,
          do: Nif.archive_entry_unset_birthtime(native)
      end

      Nif.archive_entry_set_symlink_utf8(native, entry.symlink)
      Nif.archive_entry_set_hardlink_utf8(native, entry.hardlink)
      ArchiveStream.checked(fn -> Nif.archive_write_header(ref, native) end, ref)
      {:ok, entry}
    after
      if metadata, do: Nif.archive_entry_free(native), else: Nif.archive_entry_clear(empty)
    end
  end

  @doc false
  def write!(entry, active) do
    write_header(entry, active) |> unwrap!()

    if entry.stat.type == :regular && is_nil(entry.hardlink) do
      written =
        Enum.reduce(data_stream(entry), 0, fn chunk, total ->
          data = IO.iodata_to_binary(chunk)

          count =
            ArchiveStream.checked(
              fn -> Nif.archive_write_data(active.writer.ref, data) end,
              active.writer.ref
            )

          if count != byte_size(data),
            do: raise(Archive.Error, reason: :ShortWrite, path: entry.path, action: "write")

          total + count
        end)

      if written != entry.stat.size,
        do: raise(Archive.Error, reason: :SizeMismatch, path: entry.path, action: "write")
    end

    ArchiveStream.checked(
      fn -> Nif.archive_write_finish_entry(active.writer.ref) end,
      active.writer.ref
    )

    :ok
  end

  @doc "Reads the current header into an entry, preserving native metadata."
  def read_header(entry, %ArchiveStream{entry_ref: native, reader: %{ref: ref}}) do
    clone = Nif.archive_entry_clone(native)

    source = %{
      reader: ref,
      entry: clone,
      generation: Nif.archive_entry_read_generation(clone),
      path: Nif.archive_entry_pathname_utf8(clone)
    }

    {:ok,
     %{
       entry
       | path: source.path,
         stat: Nif.archive_entry_stat(clone) |> Archive.Stat.to_file_stat(),
         symlink: Nif.archive_entry_symlink_utf8(clone),
         hardlink: Nif.archive_entry_hardlink_utf8(clone),
         source: source,
         native: clone
     }}
  end

  @doc false
  def detach(%__MODULE__{} = entry), do: %{entry | source: nil}

  defimpl Inspect do
    import Bitwise
    import Inspect.Algebra

    def inspect(%Archive.Entry{stat: %File.Stat{} = stat} = entry, opts) do
      loaded = if entry.data, do: "loaded", else: "not loaded"
      size = Archive.Utils.format_size(stat.size)
      mode = format_mode(stat.mode)
      mtime = format_time(stat.mtime)

      concat([
        "#Entry<",
        to_doc(entry.path, opts),
        ",",
        size,
        ", ",
        mode,
        ", mtime: ",
        mtime,
        ", ",
        loaded,
        ">"
      ])
    end

    defp format_mode(mode) do
      file_type = mode &&& 0o170000
      permissions = mode &&& 0o7777
      type_char = get_file_type_char(file_type)
      perms = human_readable_permissions(permissions)
      "#{type_char}#{perms}"
    end

    defp get_file_type_char(file_type) do
      case file_type do
        # socket
        0o140000 -> "s"
        # symbolic link
        0o120000 -> "l"
        # regular file
        0o100000 -> "-"
        # block device
        0o060000 -> "b"
        # directory
        0o040000 -> "d"
        # character device
        0o020000 -> "c"
        # FIFO
        0o010000 -> "p"
        # unknown
        _ -> "?"
      end
    end

    defp human_readable_permissions(mode) do
      owner = permission_string(mode, 6)
      group = permission_string(mode, 3)
      other = permission_string(mode, 0)
      "#{owner}#{group}#{other}"
    end

    defp permission_string(mode, shift) do
      r = if (mode &&& 0o400 >>> shift) != 0, do: "r", else: "-"
      w = if (mode &&& 0o200 >>> shift) != 0, do: "w", else: "-"
      x = if (mode &&& 0o100 >>> shift) != 0, do: "x", else: "-"
      "#{r}#{w}#{x}"
    end

    defp format_time(time) when is_tuple(time) do
      time
      |> NaiveDateTime.from_erl!()
      |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    end

    defp format_time(time) when is_integer(time) do
      time
      |> DateTime.from_unix!()
      |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    end
  end
end
