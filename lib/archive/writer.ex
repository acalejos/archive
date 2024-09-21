defmodule Archive.Writer do
  use Archive.Nif, as: :writer
  alias Archive.Entry

  defstruct [
    :ref,
    :entries,
    :format,
    :description,
    :entry_ref,
    :filters,
    :mode,
    total_size: 0
  ]

  @writer_opts [
    format: [
      type: {:in, @write_formats},
      required: true
    ],
    filters: [
      type: {:list, {:in, [:all | @write_filters]}},
      default: [:none]
    ]
  ]

  @writer_schema NimbleOptions.new!(@writer_opts)

  def new(opts \\ []) do
    archive_params = NimbleOptions.validate!(opts, @writer_schema)

    format = archive_params[:format]
    filters = archive_params[:filters]

    filters =
      case filters do
        :all ->
          @write_filters

        filters ->
          filters
      end

    with {:ok, entry_ref} <- call(Nif.archive_entry_new()) do
      {:ok,
       struct!(__MODULE__,
         entry_ref: entry_ref,
         format: format,
         filters: filters
       )}
    end
  end

  def new!(opts \\ []), do: new(opts) |> unwrap!()

  defp init_format(%__MODULE__{ref: ref, format: format} = archive)
       when is_reference(ref)
       when format in @write_formats do
    code = Nif.archiveFormatToInt(format)

    case call(archive_write_set_format(ref, code)) do
      :ok ->
        {:ok, archive}

      other ->
        other
    end
  end

  @doc """
  Initializes the archive with the filters specified in `new/1`
  """
  def init_filters(%__MODULE__{ref: ref, filters: filters} = archive)
      when is_reference(ref)
      when not is_nil(filters) do
    Enum.reduce_while(filters, {:ok, archive}, fn filter, status ->
      code = Nif.archiveFilterToInt(filter)

      case call(archive_write_add_filter(ref, code)) do
        :ok ->
          {:cont, status}

        {:error, _} = e ->
          {:halt, e}

        _ ->
          {:error, "Unknown failure during `#{__ENV__.function}`"}
      end
    end)
  end

  @doc """
  Initializes an `Writer` with the appropriate settings and properties.
  """
  def init(%__MODULE__{} = archive, _opts \\ []) do
    with {:ok, ref} <-
           call(Nif.archive_write_new()),
         archive = %{archive | ref: ref},
         {:ok, %__MODULE__{} = archive} <- init_filters(archive),
         {:ok, %__MODULE__{} = archive} <- init_format(archive) do
      {:ok, archive}
    end
  end

  # @spec write_streaming(__MODULE__.t(), Enumerable.t()) :: Enumerable.t()
  def write_streaming(%__MODULE__{ref: ref, entry_ref: entry_ref} = archive, filename, stream)
      when is_reference(entry_ref)
      when is_reference(ref) do
    Stream.transform(
      stream,
      fn ->
        with {:ok, %__MODULE__{ref: ref} = archive} <- init(archive),
             :ok <- call(archive_write_open_filename(ref, filename), archive.ref) do
          archive
        end
      end,
      fn %Entry{} = entry, archive ->
        with {:ok, entry} <- Entry.write_header(entry, archive),
             :ok <- call(Nif.archive_entry_clear(entry_ref)) do
          {[entry], archive}
        end
      end,
      fn %__MODULE__{ref: ref} ->
        :ok = call(archive_write_close(ref))
      end
    )
  end
end
