defmodule Archive.Entry do
  @moduledoc """
  `Archive.Entry` represents a single item in an archive.

  Most functions in this module will only work within the context of the aupplied mapping function given to `Archive.read/3`. This is because these functions require a reference to the archive while streaming and while the entry is the current item in the stream.
  """
  alias Archive.Nif
  defstruct [:ref, :path, :data, size: 0]

  @doc """
  Creates a new `Archive.Entry` struct. This is done implicitly during `Archive.read/3`.
  """
  def new() do
    {:ok, struct!(__MODULE__)}
  end

  @doc """
  Loads the entry into the archive whose reference is held by the entry. The reference to the archive is automatically passed to the current entry during `Archive.read/3`, `Archive.from_memory_streaming/3`, and `Archive.from_file_streaming/3`.
  """
  def load(%__MODULE__{data: data} = e) when is_binary(data), do: {:ok, e}

  def load(%__MODULE__{ref: nil}),
    do: {:error, "Entry must be active entry during archive stream."}

  def load(%__MODULE__{ref: ref, size: size} = entry) do
    with {:ok, data} <-
           Nif.safe_call(fn -> Nif.archive_read_data(ref, size) end) do
      {:ok, %{entry | data: data}}
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(entry, opts) do
      loaded = if entry.data, do: "loaded", else: "not loaded"
      size = Archive.Format.format_size(entry.size)

      concat([
        "#Archive.Entry<",
        to_doc(entry.path, opts),
        ", ",
        size,
        ", ",
        loaded,
        ">"
      ])
    end
  end
end
