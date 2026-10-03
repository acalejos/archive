defmodule Archive do
  @moduledoc """
  Archive operations built on `Archive.Stream`'s Enumerable and Collectable APIs.

  * `list/2` returns a snapshot of entry metadata without loading bodies.
  * `read/2` returns a snapshot with retained bodies by default.
  * `fetch/3` reads a single member without loading other bodies.
  * `write/3` writes entries or a loaded snapshot using bounded streaming.
  * `extract/2` extracts directly from a source without materializing its contents.

  Every operation has a bang variant. Non-bang operations return `{:ok, value}`
  for reads, `:ok` for writes/extraction, or `{:error, exception}`. Bang variants
  raise on failure.

  Sources are file paths, `{:file, path}`, `{:data, binary}`, or configured reader
  descriptors. Bare binaries at this level are file paths; pass `{:data, binary}`
  for in-memory archives. Low-level `reader/2` retains its `as: :auto` convenience.

      Archive.list!("backup.tar.gz")
      entry = Archive.fetch!("backup.tar.gz", "config.json")
      entry.data

      archive = Archive.read!("input.zip")
      Archive.write!(archive, "output.tar.gz", filters: :gzip)

  Snapshots preserve entry order, duplicate paths, and native metadata. Returned
  entries have no live reader cursor. A metadata-only snapshot cannot supply
  nonempty bodies to a writer; read bodies before retaining or rewriting entries.
  `read/2` intentionally materializes bodies in memory. For large archives, compose
  `reader!/2`, ordinary Elixir streams, and `writer!/2` instead.

      Archive.reader!("input.tar.gz")
      |> Stream.reject(&String.ends_with?(&1.path, ".tmp"))
      |> Enum.into(Archive.writer!("output.zip", format: :zip))

  See the [high-level guide](high_level.md) for operation contracts and the
  [streaming guide](streaming.md) for body lifetimes and bounded copying.

  `Inspect` shows a compact archive tree. Its `:custom_options` support `:depth`
  (default 3) and `:breadth` (default 2).
  """
  alias Archive.Entry
  use Archive.Nif
  use Archive.Schemas, only: [:extract_schema, :stream_schema, :reader_schema, :writer_schema]

  defstruct [
    :format,
    :compression,
    :description,
    count: 0,
    entries: [],
    total_size: 0
  ]

  @doc """
  Create a new `Archive` struct
  """
  def new() do
    struct!(__MODULE__)
  end

  @type source :: Path.t() | {:file, Path.t()} | {:data, binary()} | Archive.Stream.t()
  @type error_result :: {:error, Exception.t()}
  @type t :: %__MODULE__{
          entries: [Entry.t()],
          count: non_neg_integer(),
          total_size: non_neg_integer(),
          format: atom() | nil,
          compression: atom() | nil,
          description: String.t() | nil
        }

  @doc """
  Extracts a source to disk without loading bodies. Returns `:ok` or an error tuple.

  Secure extraction flags are enabled by default. Pass `reader: [...]` to
  configure reader options (such as passphrases), and `to:` for the destination.
  Extraction may leave files written before an error; it does not roll back.

  ## Options
  #{NimbleOptions.docs(@extract_schema)}
  """
  @spec extract(source(), keyword()) :: :ok | error_result()
  def extract(source, opts \\ []) do
    operation(fn ->
      {reader_opts, opts} = Keyword.pop(opts, :reader, [])

      with {:ok, stream} <- source_reader(source, reader_opts),
           {:ok, opts} <- Archive.Utils.handle_extract_opts(opts) do
        Enum.each(stream, fn entry -> Entry.extract_prepared(entry, opts) |> unwrap!() end)
      end
    end)
  end

  @doc "Extracts a source to disk, raising on failure."
  @spec extract!(source(), keyword()) :: :ok
  def extract!(source, opts \\ []), do: extract(source, opts) |> unwrap!()

  @doc "Compatibility helper; prefer `list/2` to create a metadata snapshot."
  def index(%__MODULE__{} = archive, %Archive.Stream{} = stream) do
    snapshot = list!(stream)

    %{
      snapshot
      | format: archive.format || snapshot.format,
        compression: archive.compression || snapshot.compression,
        description: archive.description || snapshot.description
    }
  end

  @doc false
  def update_info(%__MODULE__{} = archive, %Archive.Stream{} = stream) do
    Enum.reduce_while(stream, archive, fn entry, acc ->
      {:halt, info(acc, entry.source.reader)}
    end)
  end

  @doc false
  def update_entries(%__MODULE__{} = archive, %Archive.Stream{} = stream) do
    snapshot = list!(stream)
    %{archive | entries: snapshot.entries, count: snapshot.count, total_size: snapshot.total_size}
  end

  @doc """
  Creates a new `Archive.Stream` that is capable of reading and writing an archive.

  ## Options
  #{NimbleOptions.docs(@stream_schema)}
  """
  def stream(opts \\ []) do
    Archive.Stream.new(opts)
  end

  def stream!(opts \\ []), do: stream(opts) |> unwrap!()

  @doc """
  Creates a new `Archive.Stream` that is capable of writing an archive.

  The descriptor opens the given filepath when collection starts.

  ## Options
  See [Writer Options](#stream/1-writer-options) for a list of the full options.
  """
  def writer(path, opts \\ []) do
    Archive.stream(reader: false, writer: [{:file, path} | opts])
  end

  def writer!(path, opts \\ []), do: writer(path, opts) |> unwrap!()

  @doc """
  Creates a new `Archive.Stream` that is capable of reading an archive.

  Attempts to infer whether the passed binary is a filename or in-memory
  data to be read.

  ## Options
  See [Reader Options](#stream/1-reader-options) for a list of the full options.
  """
  def reader(path_or_data, opts \\ []) do
    Archive.stream(reader: [{:open, path_or_data} | opts], writer: false)
  end

  def reader!(path, opts \\ []), do: reader(path, opts) |> unwrap!()

  @doc """
  Lists entry metadata in one traversal, returning `{:ok, snapshot}`.

  Bodies remain unread. Snapshots preserve ordered entries and duplicate paths,
  and contain no reader cursor. Accepts the same reader options as `reader/2`.
  """
  @spec list(source(), keyword()) :: {:ok, t()} | error_result()
  def list(source, opts \\ []), do: snapshot(source, opts, false)
  @spec list!(source(), keyword()) :: t()
  def list!(source, opts \\ []), do: list(source, opts) |> unwrap!()

  @doc """
  Reads a source into an owned snapshot, returning `{:ok, snapshot}`.

  Loads all entry bodies by default. `load: false` is supported for compatibility;
  prefer `list/2` for that operation. Remaining options are reader options.
  This operation uses memory proportional to the retained bodies.
  """
  @spec read(source(), keyword()) :: {:ok, t()} | error_result()
  def read(source, opts \\ []) do
    {load?, opts} = Keyword.pop(opts, :load, true)

    with {:ok, _} <- NimbleOptions.validate([load: load?], load: [type: :boolean]) do
      snapshot(source, opts, load?)
    end
  end

  @spec read!(source(), keyword()) :: t()
  def read!(source, opts \\ []), do: read(source, opts) |> unwrap!()

  @doc """
  Reads the first member matching an exact archive pathname.

  Returns `{:ok, entry}` with a retained body or an `Archive.Error` whose reason
  is `:EntryNotFound`. Other member bodies are skipped. Duplicate paths select
  the first occurrence; no pathname normalization is performed.
  """
  @spec fetch(source(), String.t(), keyword()) :: {:ok, Entry.t()} | error_result()
  def fetch(source, path, opts \\ []) when is_binary(path) do
    operation(fn ->
      with {:ok, stream} <- source_reader(source, opts) do
        missing =
          {:error, %Archive.Error{reason: :EntryNotFound, action: "fetch entry", path: path}}

        Enum.reduce_while(stream, missing, fn entry, acc ->
          if entry.path == path,
            do: {:halt, {:ok, entry |> Entry.read_data!() |> Entry.detach()}},
            else: {:cont, acc}
        end)
      end
    end)
  end

  @spec fetch!(source(), String.t(), keyword()) :: Entry.t()
  def fetch!(source, path, opts \\ []), do: fetch(source, path, opts) |> unwrap!()

  @doc """
  Writes an enumerable of entries or a loaded snapshot. Returns `:ok` or an error.

  Bodies are forwarded in bounded chunks. The output is finalized on success;
  a failure can leave a partial output file. Returns no native writer state.
  Accepts the same options as `writer/2`.
  """
  @spec write(Enumerable.t() | t(), Path.t(), keyword()) :: :ok | error_result()
  def write(entries, path, opts \\ []) do
    operation(fn ->
      with {:ok, stream} <- writer(path, opts) do
        entries = if match?(%__MODULE__{}, entries), do: entries.entries, else: entries
        Enum.into(entries, stream)
        :ok
      end
    end)
  end

  @spec write!(Enumerable.t() | t(), Path.t(), keyword()) :: :ok
  def write!(entries, path, opts \\ []), do: write(entries, path, opts) |> unwrap!()

  defp snapshot(source, opts, load?) do
    operation(fn ->
      with {:ok, stream} <- source_reader(source, opts) do
        Archive.Stream.with_reader(stream, fn entries, ref ->
          archive =
            Enum.reduce(entries, new(), fn entry, acc ->
              entry = if load?, do: Entry.read_data!(entry), else: entry

              %{
                acc
                | entries: [Entry.detach(entry) | acc.entries],
                  count: acc.count + 1,
                  total_size: acc.total_size + entry.stat.size
              }
            end)

          archive = info(archive, ref)
          {:ok, %{archive | entries: Enum.reverse(archive.entries)}}
        end)
      end
    end)
  end

  defp info(archive, ref) do
    %{
      archive
      | format: archive.format || Nif.archiveFormatToAtom(Nif.archive_format(ref)),
        compression:
          archive.compression || Nif.archiveFilterToAtom(Nif.archive_filter_code(ref, 0)),
        description: archive.description || Nif.archive_format_name(ref)
    }
  end

  defp source_reader(%Archive.Stream{reader: nil}, _) do
    {:error, ArgumentError.exception("source descriptor has no reader")}
  end

  defp source_reader(%Archive.Stream{} = stream, []), do: {:ok, stream}

  defp source_reader(%Archive.Stream{}, _) do
    {:error,
     ArgumentError.exception("configure reader options when constructing the source descriptor")}
  end

  defp source_reader({:file, path}, opts) when is_binary(path),
    do: typed_reader(path, opts, :file)

  defp source_reader({:data, data}, opts) when is_binary(data),
    do: typed_reader(data, opts, :data)

  defp source_reader(path, opts) when is_binary(path),
    do: reader(path, Keyword.put_new(opts, :as, :file))

  defp source_reader(_, _),
    do:
      {:error,
       ArgumentError.exception(
         "expected a path, {:file, path}, {:data, binary}, or reader descriptor"
       )}

  defp typed_reader(value, opts, kind) do
    if Keyword.get(opts, :as, kind) in [kind, :auto],
      do: reader(value, Keyword.put(opts, :as, kind)),
      else: {:error, ArgumentError.exception("as: option conflicts with the tagged source")}
  end

  defp operation(fun) do
    fun.()
  rescue
    e in [Archive.Error, ErlangError, ArgumentError, File.Error, NimbleOptions.ValidationError] ->
      {:error, e}
  end

  defimpl Inspect do
    import Inspect.Algebra

    @default_depth 3
    @default_breadth 2

    def inspect(%{entries: entries, description: desc} = s, opts) do
      struct_name = s.__struct__ |> Module.split() |> Enum.reverse() |> hd()
      entries = if is_map(entries), do: entries, else: Archive.Utils.hierarchical(entries)
      depth = opts.custom_options[:depth] || @default_depth
      breadth = opts.custom_options[:breadth] || @default_breadth

      format_str = if desc, do: "[#{desc}]", else: ""

      cond do
        is_nil(entries) || entries == [] || entries == %{} ->
          concat(["##{struct_name}", format_str, "<", color("initialized", :yellow, opts), ">"])

        true ->
          summary = summarize_archive(s.entries)

          header =
            concat([
              color(
                "#{summary.total_entries} entries (#{summary.total_loaded} loaded)",
                :blue,
                opts
              ),
              ", ",
              color(Archive.Utils.format_size(summary.total_size), :magenta, opts)
            ])

          separator = color(String.duplicate("─", 15), :grey, opts)
          tree = build_tree(entries, depth, breadth, 1, opts)

          concat([
            "##{struct_name}",
            format_str,
            "<",
            nest(concat([line(), header, line(), separator, line(), tree]), 2),
            line(),
            ">"
          ])
      end
    end

    defp summarize_archive(entries) when is_list(entries) do
      Enum.reduce(entries, %{total_entries: 0, total_size: 0, total_loaded: 0}, fn entry, acc ->
        %{
          acc
          | total_entries: acc.total_entries + 1,
            total_size: acc.total_size + (entry.stat.size || 0),
            total_loaded: acc.total_loaded + if(entry.data, do: 1, else: 0)
        }
      end)
    end

    defp summarize_archive(entries) when is_map(entries) do
      Enum.reduce(entries, %{total_entries: 0, total_size: 0, total_loaded: 0}, fn
        {_, %Archive.Entry{stat: %File.Stat{size: size}, data: data}}, acc ->
          %{
            acc
            | total_entries: acc.total_entries + 1,
              total_size: acc.total_size + (size || 0),
              total_loaded: acc.total_loaded + ((data && 1) || 0)
          }

        {_, sub_entries}, acc when is_map(sub_entries) ->
          sub_summary = summarize_archive(sub_entries)

          %{
            total_entries: acc.total_entries + sub_summary.total_entries,
            total_size: acc.total_size + sub_summary.total_size,
            total_loaded: acc.total_loaded + sub_summary.total_loaded
          }
      end)
    end

    defp summarize_archive(_), do: %{total_entries: 0, total_size: 0}

    defp build_tree(entries, depth, breadth, current_depth, opts)
         when is_map(entries) and current_depth <= depth do
      entries
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.take(breadth)
      |> Enum.map(&format_entry(&1, current_depth, depth, breadth, opts))
      |> Enum.intersperse(line())
      |> concat()
      |> maybe_add_ellipsis(entries, breadth, current_depth, opts)
    end

    defp build_tree(_, _, _, _, _), do: empty()

    defp format_entry(
           {name, %Archive.Entry{stat: %File.Stat{size: size}, data: data}},
           current_depth,
           _,
           _,
           opts
         ) do
      concat([
        String.duplicate("  ", current_depth),
        color(name, :blue, opts),
        " (",
        color(Archive.Utils.format_size(size), :cyan, opts),
        ")",
        if(data, do: "(*)", else: "")
      ])
    end

    defp format_entry({name, sub_entries}, current_depth, depth, breadth, opts)
         when is_map(sub_entries) do
      summary = summarize_archive(sub_entries)
      sub_tree = build_tree(sub_entries, depth, breadth, current_depth + 1, opts)

      concat([
        String.duplicate("  ", current_depth),
        color("#{name}/", :yellow, opts),
        " (",
        color(
          "#{summary.total_entries} #{(summary.total_entries == 1 && "item") || "items"}",
          :blue,
          opts
        ),
        ", ",
        color(Archive.Utils.format_size(summary.total_size), :cyan, opts),
        ")",
        if(sub_tree != empty(), do: concat([line(), sub_tree]), else: empty())
      ])
    end

    defp format_entry({name, _}, current_depth, _, _, opts) do
      concat([
        String.duplicate("  ", current_depth),
        color(name, :red, opts),
        " (unknown)"
      ])
    end

    defp maybe_add_ellipsis(tree, entries, breadth, current_depth, opts) do
      if map_size(entries) > breadth do
        concat([
          tree,
          line(),
          String.duplicate("  ", current_depth),
          color("... and #{map_size(entries) - breadth} more", :yellow, opts)
        ])
      else
        tree
      end
    end
  end
end
