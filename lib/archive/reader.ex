defmodule Archive.Reader do
  use Archive.Nif, as: :reader
  require Logger
  alias Archive.Entry

  defstruct [
    :ref,
    :entries,
    :format,
    :description,
    :entry_ref,
    :formats,
    :filters,
    total_size: 0
  ]

  @reader_opts [
    formats: [
      type:
        {:or,
         [
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
      default: [only: @read_formats]
    ],
    filters: [
      type:
        {:or,
         [
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
      default: [only: @read_filters]
    ]
  ]

  @reader_schema NimbleOptions.new!(@reader_opts)

  def new(opts \\ []) do
    archive_params = NimbleOptions.validate!(opts, @reader_schema)

    formats = archive_params[:formats]
    filters = archive_params[:filters]

    formats =
      case formats do
        [only: keep_formats] ->
          keep_formats

        [except: exclude_formats] ->
          @read_formats |> Enum.filter(&(&1 not in exclude_formats))
      end

    filters =
      case filters do
        [only: keep_filters] ->
          keep_filters

        [except: exclude_filters] ->
          @read_filters |> Enum.filter(&(&1 not in exclude_filters))
      end

    with {:ok, entry_ref} <- call(Nif.archive_entry_new()) do
      {:ok,
       struct!(__MODULE__,
         entry_ref: entry_ref,
         formats: formats,
         filters: filters
       )}
    end
  end

  def new!(opts \\ []), do: new(opts) |> unwrap!()

  @doc """
  Initializes the archive with the formats specified in `new/1`
  """
  def init_formats(%__MODULE__{ref: ref, formats: formats} = archive)
      when is_reference(ref)
      when not is_nil(formats) do
    Enum.reduce_while(formats, {:ok, archive}, fn format, status ->
      code = Nif.archiveFormatToInt(format)

      case call(archive_read_support_format_by_code(ref, code)) do
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
  Initializes the archive with the filters specified in `new/1`
  """
  def init_filters(%__MODULE__{ref: ref, filters: filters} = archive)
      when is_reference(ref)
      when not is_nil(filters) do
    Enum.reduce_while(filters, {:ok, archive}, fn filter, status ->
      code = Nif.archiveFilterToInt(filter)

      case call(archive_read_support_filter_by_code(ref, code)) do
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
  Initializes an `Archive` with the appropriate settings and properties.
  """
  def init(%__MODULE__{} = archive, _opts \\ []) do
    with {:ok, ref} <-
           call(archive_read_new()),
         archive = %{archive | ref: ref},
         {:ok, %__MODULE__{} = archive} <- init_filters(archive),
         {:ok, %__MODULE__{} = archive} <- init_formats(archive) do
      {:ok, archive}
    end
  end

  def init!(%__MODULE__{} = archive, opts \\ []), do: init(archive, opts) |> unwrap!()

  defp stream_archive(init_fn, fun) do
    Stream.resource(
      init_fn,
      fn
        {%__MODULE__{} = archive, has_info} ->
          with :ok <-
                 call(
                   archive_read_next_header(archive.ref, archive.entry_ref),
                   archive.ref
                 ),
               {:ok, pathname} <-
                 call(Nif.archive_entry_pathname(archive.entry_ref)),
               {:ok, zig_stat} <-
                 call(Nif.archive_entry_stat(archive.entry_ref)),
               %File.Stat{} = stat <- Nif.to_file_stat(zig_stat),
               {:ok, %Entry{} = entry} <- Entry.new(path: pathname, stat: stat) do
            element = if is_function(fun, 2), do: fun.(entry, archive), else: fun.(entry)

            element =
              if is_list(element),
                do: element,
                else: [element]

            {archive, element} =
              if has_info do
                {archive, element}
              else
                # This lets us gather metadata information after the first header is read
                # as a Keyword, we can add to this later if needed
                info = [
                  format: Nif.archive_format(archive.ref) |> Nif.archiveFormatToAtom(),
                  description: Nif.archive_format_name(archive.ref)
                ]

                {archive, [info | element]}
              end

            {element, {archive, true}}
          else
            {:error, error} when error in [:ArchiveFatal, :ArchiveEof] ->
              {:halt, archive}

            {:error, reason} ->
              {:halt, {{:error, reason}, archive}}
          end
      end,
      fn
        {{:error, _reason}, %__MODULE__{ref: ref}} ->
          :ok = call(archive_read_close(ref))

        %__MODULE__{ref: ref} ->
          :ok = call(archive_read_close(ref))
      end
    )
  end

  @doc """
  Streams the contents of an archive from a file, applying the supplied function to each entry.

  Refer to `read/3` for more information about the supplied function.
  """
  def from_file_streaming(%__MODULE__{ref: nil} = archive, filename, fun)
      when is_binary(filename)
      when is_function(fun, 2) or is_function(fun, 1) do
    init_fn = fn ->
      with true <- File.regular?(filename),
           {:ok, %__MODULE__{ref: ref} = archive} <- init(archive),
           :ok <-
             call(archive_read_open_filename(ref, filename, 10240), archive.ref) do
        {archive, false}
      else
        false ->
          {:error, "Bad file"}

        {:error, error} ->
          {:error, error}
      end
    end

    stream_archive(init_fn, fun)
  end

  def from_file_streaming(%__MODULE__{}, _, _),
    do: {:error, "You must use a new archive with `Archive.new/0`"}

  @doc """
  Streams the contents of an archive from memory, applying the supplied function to each entry.

  Refer to `read/3` for more information about the supplied function.
  """
  def from_memory_streaming(%__MODULE__{ref: nil} = archive, data, fun)
      when is_binary(data)
      when is_function(fun, 2) or is_function(fun, 1) do
    init_fn = fn ->
      with {:ok, %__MODULE__{ref: ref} = archive} <- init(archive),
           :ok <-
             call(archive_read_open_memory(ref, data), archive.ref) do
        {archive, false}
      else
        {:error, error} ->
          {:error, error}
      end
    end

    stream_archive(init_fn, fun)
  end

  def from_memory_streaming(%__MODULE__{}, _, _),
    do: {:error, "You must use a new archive with `Archive.new/0`"}

  @doc """
  Reads the content of an archive.

  This function populates meta-data about the archive, such as total archive size and archive format.

  ## Options
  * `:with` - Applies the supplied function to each `Archive.Entry`.
      Can be either an arity-1 function, which only received the current `Archive.Entry`, or an
      arity-2 function that recieves the entry and the `Archive`. Defaults to the identity function.
  * `:as` - How to collect the entries. Can be `:list` or `:map`, where `:map` creates a hierarchical
      filesystem-like representation of the entries. Defaults to `:map`.
  """
  def read(
        %__MODULE__{} = archive,
        filename_or_data,
        opts \\ []
      ) do
    opts = Keyword.validate!(opts, as: :map, with: & &1)

    unless opts[:as] in [:map, :list] do
      raise ArgumentError,
            "Options `:as` must be either `:map` or `:list`, got #{inspect(opts[:as])}"
    end

    unless is_function(opts[:with], 2) or is_function(opts[:with], 1) do
      raise ArgumentError, "Option `:with` must be an arity-2 anonymous function"
    end

    entries =
      if File.regular?(filename_or_data) do
        from_file_streaming(archive, filename_or_data, opts[:with])
      else
        from_memory_streaming(archive, filename_or_data, opts[:with])
      end

    case entries do
      {:error, _} = e ->
        e

      _ ->
        entries =
          entries
          |> Enum.to_list()
          |> Enum.filter(& &1)

        [info | entries] = entries

        total_size =
          Enum.reduce(entries, 0, fn %Entry{stat: %File.Stat{size: size}}, total ->
            size + total
          end)

        fields =
          info ++
            [
              total_size: total_size,
              entries:
                if(opts[:as] == :map, do: Archive.Utils.hierarchical(entries), else: entries)
            ]

        {:ok,
         struct!(
           archive,
           fields
         )}
    end
  end

  def read!(%__MODULE__{} = archive, filename_or_data, opts \\ []),
    do: read(archive, filename_or_data, opts) |> unwrap!()
end
