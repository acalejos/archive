defmodule Archive.Stream do
  use Archive.Nif

  defstruct [
    :writer,
    :reader,
    :entry_ref
  ]

  @reader_opts [
    formats: [
      type:
        {:or,
         [
           {:in, @read_formats},
           {:list, {:in, @read_formats}},
           keyword_list: [
             only: [
               type: {:list, {:in, @read_formats}}
             ]
           ],
           keyword_list: [
             except: [
               type: {:list, {:in, @read_formats}}
             ]
           ]
         ]},
      default: @read_formats
    ],
    filters: [
      type:
        {:or,
         [
           {:in, @read_filters},
           {:list, {:in, @read_filters}},
           keyword_list: [
             only: [
               type: {:list, {:in, @read_filters}}
             ]
           ],
           keyword_list: [
             except: [
               type: {:list, {:in, @read_filters}}
             ]
           ]
         ]},
      default: @read_filters
    ],
    open: [type: :string, required: true],
    as: [type: {:in, [:file, :data, :auto]}, default: :auto]
  ]
  @writer_opts [
    format: [
      type: {:in, @write_formats},
      default: :tar
    ],
    filters: [
      type: {:or, [{:in, [:all | @write_filters]}, {:list, {:in, @write_filters}}]},
      default: :none
    ],
    file: [type: :string, required: true]
  ]

  @archive_stream_opts [
    writer: [
      type: {:or, [:boolean, keyword_list: @writer_opts]},
      default: [format: :tar, filters: :none]
    ],
    reader: [
      type: {:or, [{:in, [false]}, keyword_list: @reader_opts]},
      default: [formats: @read_formats, filters: @read_filters]
    ]
  ]

  @archive_stream_schema NimbleOptions.new!(@archive_stream_opts)

  def new(opts \\ []) do
    with {:ok, archive_params} <- NimbleOptions.validate(opts, @archive_stream_schema),
         {:ok, entry_ref} <- call(Nif.archive_entry_new()),
         {:ok, read_ref} <-
           if(archive_params[:reader], do: call(Nif.archive_read_new()), else: {:ok, nil}),
         {:ok, write_ref} <-
           if(archive_params[:writer], do: call(Nif.archive_write_new()), else: {:ok, nil}) do
      writer =
        if archive_params[:writer] do
          archive_params[:writer]
          |> Enum.into(%{})
          |> Map.update!(:filters, fn
            filters when is_list(filters) ->
              filters

            :all ->
              @write_filters

            filter ->
              [filter]
          end)
          |> Map.update!(:format, fn format -> [format] end)
          |> Map.put(:ref, write_ref)
        end

      reader =
        if archive_params[:reader] do
          archive_params[:reader]
          |> Enum.into(%{})
          |> Map.update!(:formats, fn
            [only: formats] ->
              formats

            [except: formats] ->
              @write_formats |> Enum.filter(&(&1 in formats))

            formats when is_list(formats) ->
              formats

            format ->
              [format]
          end)
          |> Map.update!(:filters, fn
            [only: filters] ->
              filters

            [except: filters] ->
              @write_filters |> Enum.filter(&(&1 in filters))

            filters when is_list(filters) ->
              filters

            filter ->
              [filter]
          end)
          |> then(
            &Map.update!(&1, :as, fn
              :auto ->
                if(File.regular?(&1[:open]), do: :file, else: :data)

              other ->
                other
            end)
          )
          |> Map.put(:ref, read_ref)
        end

      {:ok,
       struct!(__MODULE__,
         entry_ref: entry_ref,
         writer: writer,
         reader: reader
       )}
    end
  end

  @doc """
  Initializes the archive with the formats specified in `new/1`
  """
  def init(%__MODULE__{} = archive) do
    zipped =
      [
        archive.reader &&
          {archive.reader.filters, &Nif.archiveFilterToInt/1,
           &Nif.archive_read_support_filter_by_code/2, archive.reader.ref},
        archive.writer &&
          {archive.writer.format, &Nif.archiveFormatToInt/1, &Nif.archive_write_set_format/2,
           archive.writer.ref},
        archive.writer &&
          {archive.writer.filters, &Nif.archiveFilterToInt/1, &Nif.archive_write_add_filter/2,
           archive.writer.ref},
        archive.reader &&
          {archive.reader.formats, &Nif.archiveFormatToInt/1,
           &Nif.archive_read_support_format_by_code/2, archive.reader.ref}
      ]
      |> Enum.filter(& &1)

    Enum.reduce_while(zipped, {:ok, archive}, &process_option_group/2)
  end

  defp process_option_group({options, code_func, support_func, ref}, {:ok, archive}) do
    case apply_support(options, code_func, support_func, ref) do
      :ok -> {:cont, {:ok, archive}}
      error -> {:halt, error}
    end
  end

  defp apply_support(options, code_func, support_func, ref) do
    Enum.reduce_while(options, :ok, fn option, _acc ->
      code = code_func.(option)

      case call(support_func.(ref, code)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, "Unknown failure for option #{inspect(option)}"}}
      end
    end)
  end

  def init!(%__MODULE__{} = archive), do: init(archive) |> unwrap!()

  defimpl Enumerable do
    def reduce(%Archive.Stream{reader: %{open: path_or_data, as: open_as}} = archive, acc, fun) do
      start_fn =
        fn ->
          with {:ok, %Archive.Stream{reader: %{ref: ref}} = archive} <-
                 Archive.Stream.init(%{archive | writer: false}),
               :ok <-
                 if(open_as == :file,
                   do: call(Nif.archive_read_open_filename(ref, path_or_data, 10240), ref),
                   else: call(Nif.archive_read_open_memory(ref, path_or_data), ref)
                 ) do
            archive
          else
            {:error, error} ->
              {:error, error}
          end
        end

      next_fn = fn
        %Archive.Stream{entry_ref: entry_ref, reader: %{ref: ref}} = archive ->
          with :ok <-
                 call(
                   Nif.archive_read_next_header(ref, entry_ref),
                   ref
                 ),
               {:ok, %Archive.Entry{} = entry} <- Archive.Entry.new(),
               {:ok, %Archive.Entry{} = entry} <- Archive.Entry.read_header(entry, archive) do
            {[entry], archive}
          else
            {:error, error} when error in [:ArchiveFatal, :ArchiveEof] ->
              {:halt, archive}

            {:error, reason} ->
              {:halt, {{:error, reason}, archive}}
          end
      end

      # Nif.archive_refresh does the following:
      # 1. Closes and frees the object associated with the existing resource
      # 2. Creates a new archive_reader object and updates the reference to point to this new object
      #  It does this so we don't have to reassign the reader manually in Elixir since readers are only
      #  good for one stream. After closing a reader you cannot reopen.
      Stream.resource(start_fn, next_fn, &call(Nif.archive_read_refresh(&1.reader.ref))).(
        acc,
        fun
      )
    end

    def count(_stream) do
      {:error, __MODULE__}
    end

    def member?(_stream, _term) do
      {:error, __MODULE__}
    end

    def slice(_stream) do
      {:error, __MODULE__}
    end
  end

  defimpl Collectable do
    def into(%Archive.Stream{entry_ref: entry_ref, writer: %{file: path}} = archive)
        when is_reference(entry_ref) do
      with {:ok, %Archive.Stream{writer: %{ref: ref}} = archive} <-
             Archive.Stream.init(%{archive | reader: false}),
           :ok <- call(Nif.archive_write_open_filename(ref, path), ref) do
        {:ok, _into(archive)}
      end
    end

    defp _into(
           %Archive.Stream{writer: %{ref: ref}, entry_ref: entry_ref} =
             archive
         ) do
      fn
        _, {:cont, %Archive.Entry{} = entry} ->
          with {:ok, %Archive.Entry{} = entry} <- Archive.Entry.write_header(entry, archive),
               :ok <- call(Nif.archive_entry_clear(entry_ref), ref) do
            {[entry], archive}
          end

        _, :done ->
          :ok = call(Nif.archive_write_refresh(ref))
          archive

        _, :halt ->
          :ok = call(Nif.archive_write_refresh(ref))
      end
    end
  end
end
