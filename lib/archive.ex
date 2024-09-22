defmodule Archive do
  @moduledoc """
  `Archive` provides Elixir bindings to [`libarchive`](https://github.com/libarchive/libarchive) through the power of the wonderful [`Zigler`](https://hexdocs.pm/zigler/Zig.html) library.

  `Archive` provides a high-level API for interacting with archive files.

  Like `libarchive`, `Archive` treats all files as streams first and foremost, but provides many convenient high-level APIs to make it more natural to work with archive.

  > #### Early Development {: .warning}
  >
  > `Archive` is still very early in its development, and currently only supports reading archives with all formats, compressions, and filters enabled. In the future, these will be configurable parameters.


  ## Reading

  As streams, archives are not conducive to random-access reads or seeks. Once archives are opened and read, they must be closed and reopened to read again. It is often a two-stage process to read an archive, where you read a list of the contents first, then selectively filter which items you want suring a second pass.

  `Archive` takes care of all resource allocations, initializations, and cleanup for you. Using the high-level API, you only need to provide a mapping function to determine what to do with each entry as it is streamed.

  > #### The High-Level API {: .info}
  >
  > `Archive`'s high-level API consists of the following:
  >    1) `read/3` - The main entry-point for reading archive contents as an `Enumerable`, since it automatically collects the entries. `read/3` can work for both file-based reads and memory-based reads.
  >    2) `from_file_streaming/3` - Streams the contents of the archive from a file, applying the supplied function.
  >    3) `from_memory_streaming/3` - Streams the contents of the archive from memory, applying the supplied function.

  > #### The Low-Level Reading Loop {: .info}
  >
  > Although `Archive`'s high-level API takes care of all of the resource management for you, it can still be useful to understand how it works:
  >   1) Create new archive reader object
  >   2) Update any global reader properties as appropriate. These properties determine supported compressions, formats, etc.
  >   3) Open the archive
  >   4) Repeatedly call archive_read_next_header to get information about
  >       successive archive entries.  Call archive_read_data to extract
  >      data for entries of interest.
  >   5) Cleanup archive reader object

  The mapping function will accept an `Archive.Entry` struct, which will contain metadata (such as path and size) information about the entry. You can use that information to determine what to do in your function.

  You can also use function from the `Archive.Entry` module to perform different operations with the entry (most commonly `Archive.Entry.load/2`).

  > #### Usage of `Archive.Entry` functions {: .error}
  >
  > It is generally discouraged to use function from the `Archive.Entry` module outside of the context of a function passed to the high-level API.
  >
  > As mentioned earlier, since archives are all streaming objects, each entry can only be operated on while it is the current entry in the stream. If you try to use functions from the `Archive.Entry` module while outside of the loop you provide to the various high-level APIs, it is up to you to also supply the `Archive` struct. The high-level API takes care of ensuring that the `Archive` gets passed in.

  ### Examples

  Setup the archive

  ```elixir
  data = File.read!("/path/to/data.zip")
  {:ok, a} = Archive.new()
  ```

  Read the index of entries. Notice that the output of inspection
  will show you how many items are in the archive (given the function you supplied to `Archive.read/3`), the archive format, the size of the archive, and more.

  ```elixir
  {:ok, a} = Archive.read(a, data)
  ```

  ```
  {:ok, #Archive[zip]<
   147 entries (0 loaded), 506.0 KB
   ───────────────
     .editorconfig (166 B)
     .github/ (1 items, 338 B)
       workflows/ (1 items, 338 B)
         deploy-theme.yml (338 B)
     ... and 21 more
  >}
  ```

  Here's an example of reading into memory all entries that are larger than 1500 bytes, and store the entries as a list (rather than as a hierarchical map):

  ```elixir
  {:ok, a} =
  Archive.read(a, data,
    with: fn entry, archive ->
      if entry.size > 1500 do
        {:ok, entry} = Archive.Entry.load(entry, archive)
        entry
      else
        entry
      end
      end, as: :list
  )
  ```

  ```
  {:ok, #Archive[zip]<
   147 entries (40 loaded), 506.0 KB
   ───────────────
     .editorconfig (166 B)
     .github/ (1 items, 338 B)
       workflows/ (1 items, 338 B)
         deploy-theme.yml (338 B)
     ... and 21 more
  >}
  ```

  ## Writing

  > #### TODO {: .error}
  >
  > `Archive` is still very early in development and does not implement any of the writing API yet.


  ## `Inspect`

  `Archive.Reader`, `Archive.Writer`, and `Archive.Entry` provide custom implementations for the `Inspect` protocol.

  When inspecting `Archive.{Reader, Writer}`, the following custom options can be supplied to the `custom_options` option of inspect:

  * `:depth` - Depth of directories to display. Defaults to 3.
  * `:breadth` - Breadth of items to display. Defaults to 2.

  ### Examples

  ```elixir
  IO.inspect(%Archive.Reader{} = a, custom_options: [depth: 3, breadth: 2])
  ```

  ```
  #Reader[zip]<
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
  defstruct [
    :format,
    :description,
    entries: [],
    total_size: 0
  ]

  defimpl Inspect, for: [Archive.Reader, Archive.Writer] do
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
