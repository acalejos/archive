defmodule Archive do
  @moduledoc """
  `Archive` provides Elixir bindings to [`libarchive`](https://github.com/libarchive/libarchive) through the power of the wonderful [`Zigler`](https://hexdocs.pm/zigler/Zig.html) library.

  `Archive` provides a high-level API for interacting with archive files.

  ### Intro to `Archive`'s APIs
  <!-- tabs-open -->

  ### High-Level API

  The `Archive` API is the highest-level API offered by `Archive`, and mostly consists of convenience functions for common
  use cases with archives. It involves using the `Archive` struct as a container for archive information extracted from
  archives using the `Archive.Stream` API.

  It also implements the `Inspect` protocol specially for providing information about the archive in a succinct manner.

  ### Streaming API

  `Archive` implements archive traversal, reading, and writing as
  streams. It does this in the `Archive.Stream` module.

  `Archive.Stream` implements both the `Enumerable` and `Collectable` protocol, modeled after `File.Stream` from the
  standard library. This allows you to read from an archive, perform transformations, and redirect to a new archive,
  all lazily.

  All implementations in the high-level API are built off of the streaming API.

  ### Low-Level API

  > ####  Caution {: .error}
  >
  > The low-level API is a nearly one-to-one mapping to the `libarchive` C API. All of the low-level API
  > lives in the `Archive.Nif` module, and it is highly recommended to not use this API directly.
  >
  > If you choose to use this API, you will need to carefully consider resource management and proper error checking.

  <!-- tabs-close -->

  Realistically, you will likely mix the High-Level API and the Streaming API, since the Streaming API is required to
  traverse the archive.

  ## Concepts

  Like `libarchive`, `Archive` treats all files as streams first and foremost, but provides many convenient high-level APIs to make it more natural to work with archive.

  There are four major operations that `Archive` performs:
  * [Reading Archives](#module-reading-archives)
  * [Writing Archives](#module-writing-archives)
  * [Writing to Disk](#module-writing-to-disk)
  * [Extracting to Disk](#module-extracting-to-disk)

  ### Reading Archives

  As streams, archives are not conducive to random-access reads or seeks. Once archives are opened and read, they must be closed and reopened to read again. It is often a two-stage process to read an archive, where you read a list of the contents first, then selectively filter which items you want suring a second pass.

  `Archive` takes care of all resource allocations, initializations, and cleanup for you. Using the high-level API, you only need to provide a mapping function to determine what to do with each entry as it is streamed.

  The mapping function will accept an `Archive.Entry` struct, which will contain metadata (such as path and size) information about the entry. You can use that information to determine what to do in your function.

  You can also use function from the `Archive.Entry` module to perform different operations with the entry (most commonly `Archive.Entry.load/2`).

  ### Writing Archives

  TODO

  ### Writing to Disk

  TODO

  ### Extracting to Disk

  TODO

  ## `Inspect`

  `Archive`, `Archive.Stream`, and `Archive.Entry` provide custom implementations for the `Inspect` protocol.

  When inspecting `Archive`, the following custom options can be supplied to the `custom_options` option of inspect:

  * `:depth` - Depth of directories to display. Defaults to 3.
  * `:breadth` - Breadth of items to display. Defaults to 2.

  ### Examples

  ```elixir
  IO.inspect(%Archive{} = a, custom_options: [depth: 3, breadth: 2])
  ```

  ```
  #Archive[zip]<
  147 entries (40 loaded), 506.0 KB
  ───────────────
    .editorconfig (166 B)
    .github/ (1 items, 338 B)
      workflows/ (1 items, 338 B)
        deploy-theme.yml (338 B)
    ... and 21 more
  >
  ```
  """
  alias Archive.Entry
  use Archive.Nif
  use Archive.Schemas, only: [:extract_schema, :stream_schema, :reader_schema, :writer_schema]

  defstruct [
    :format,
    :compression,
    :description,
    :count,
    entries: [],
    total_size: 0
  ]

  @doc """
  Create a new `Archive` struct
  """
  def new() do
    struct!(__MODULE__)
  end

  @doc """
  Extracts the archive from the reader stream, extracting the archive
  to disk.

  As opposed to the other `write` operations, which write a new archive,
  `extract` extracts the archive to disk at the target location.

  ## Options
  #{NimbleOptions.docs(@extract_schema)}
  """
  def extract(%Archive.Stream{} = stream, opts \\ []) do
    {:ok, opts} = Archive.Utils.handle_extract_opts(opts)
    {destination, opts} = Keyword.pop(opts, :to)

    if destination do
      File.cd!(destination, fn -> extract_archive(stream, opts) end)
    else
      extract_archive(stream, opts)
    end
  end

  defp extract_archive(%Archive.Stream{} = stream, opts) do
    Enum.each(stream, fn entry ->
      Entry.extract(entry, stream, opts)
    end)
  end

  def index(%__MODULE__{} = archive, %Archive.Stream{} = stream) do
    archive
    |> update_entries(stream)
    |> update_info(stream)
  end

  def update_info(%__MODULE__{} = archive, %Archive.Stream{} = stream) do
    Enum.reduce_while(stream, archive, fn %Entry{},
                                          %Archive{
                                            compression: compression,
                                            format: format,
                                            description: description
                                          } = acc ->
      format =
        if format do
          format
        else
          case call(Nif.archive_format(stream.reader.ref)) do
            {:ok, code} when is_integer(code) ->
              Nif.archiveFormatToAtom(code)

            _ ->
              nil
          end
        end

      compression =
        if compression do
          compression
        else
          case call(Nif.archive_compression(stream.reader.ref)) do
            {:ok, code} when is_integer(code) ->
              Nif.archiveFilterToAtom(code)

            _ ->
              nil
          end
        end

      description =
        if description do
          description
        else
          case call(Nif.archive_format_name(stream.reader.ref)) do
            {:ok, name} when is_binary(name) ->
              name

            _ ->
              nil
          end
        end

      acc =
        %{
          acc
          | format: format,
            description: description,
            compression: compression
        }

      if format && description && compression do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  def update_entries(%__MODULE__{} = archive, %Archive.Stream{} = stream) do
    archive =
      Enum.reduce(stream, %{archive | entries: []}, fn %Entry{stat: %File.Stat{size: size}} =
                                                         entry,
                                                       %Archive{
                                                         total_size: total_size,
                                                         entries: entries
                                                       } ->
        entries = [entry | entries]
        total_size = total_size + size
        %{archive | entries: entries, total_size: total_size}
      end)

    Map.update!(archive, :entries, &Enum.reverse/1)
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

  Opens the writer at the given filepath.

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
          summary = summarize_archive(entries)

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
