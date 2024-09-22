defmodule Archive.Entry do
  @moduledoc """
  `Archive.Entry` represents a single item in an archive.

  Most functions in this module will only work within the context of the aupplied mapping function given to `Archive.read/3`. This is because these functions require a reference to the archive while streaming and while the entry is the current item in the stream.
  """
  use Archive.Nif
  alias Archive.Stream

  defstruct [
    :stat,
    :path,
    :data
  ]

  @type t :: %__MODULE__{
          stat: File.Stat.t(),
          path: String.t(),
          data: binary() | nil
        }

  @doc """
  Creates a new `Archive.Entry` struct. This is done implicitly during `Archive.read/3`.
  """
  def new(fields \\ []) do
    {:ok, struct!(__MODULE__, fields)}
  end

  def new!(fields \\ []), do: new(fields) |> unwrap!()

  @doc """
  Loads the entry data into the archive. The archive is automatically passed to the current entry during `Archive.read/3`, `Archive.from_memory_streaming/3`, and `Archive.from_file_streaming/3`.
  """
  def read_data(%__MODULE__{data: data} = e, _) when is_binary(data), do: {:ok, e}

  def read_data(%__MODULE__{stat: %File.Stat{size: size}} = entry, %Stream{reader: %{ref: ref}}) do
    with {:ok, data} <-
           Nif.safe_call(
             fn -> Nif.archive_read_data(ref, size) end,
             ref
           ) do
      {:ok, %{entry | data: data}}
    end
  end

  def read_data!(%__MODULE__{} = entry, %Stream{} = archive),
    do: read_data(entry, archive) |> unwrap!()

  def write_header(
        %__MODULE__{path: path, stat: %File.Stat{} = stat} = entry,
        %Stream{entry_ref: entry_ref, writer: %{ref: ref}}
      ) do
    with :ok <- call(Nif.archive_entry_set_pathname(entry_ref, path), ref),
         :ok <-
           call(Nif.archive_entry_copy_stat(entry_ref, Nif.file_stat_to_zig_map(stat)), ref),
         :ok <- call(Nif.archive_write_header(ref, entry_ref), ref) do
      {:ok, entry}
    end
  end

  def read_header(%__MODULE__{} = entry, %Stream{entry_ref: entry_ref, reader: %{ref: ref}})
      when is_reference(entry_ref)
      when is_reference(ref) do
    with {:ok, pathname} <- call(Nif.archive_entry_pathname(entry_ref)),
         {:ok, zig_stat} <- call(Nif.archive_entry_stat(entry_ref)),
         %File.Stat{} = stat <- Nif.to_file_stat(zig_stat) do
      {:ok, struct!(entry, path: pathname, stat: stat)}
    end
  end

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
