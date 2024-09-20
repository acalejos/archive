defmodule Archive do
  alias Archive.Nif
  alias Archive.Entry

  import Archive.Nif, only: [unwrap!: 1]

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

  `Archive` and `Archive.Entry` provide custom implementations for the `Inspect` protocol.

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

  defstruct [:ref, :entries, :format, :description, :entry_ref, total_size: 0]

  @doc """
  Creates a new `Archive` struct. This must be initialized before any IO operations can occur.
  """
  def new() do
    with {:ok, entry_ref} <- Nif.safe_call(&Nif.archive_entry_new/0) do
      {:ok, struct!(__MODULE__, entry_ref: entry_ref)}
    end
  end

  def new!(), do: new() |> unwrap!()

  @doc """
  Initializes an `Archive` with the appropriate settings and properties.

  > #### Properties and Settings {: .info}
  >
  > Currently, the properties and settings are not configurable. The default is to support all archive formats (including raw), all compression formats, and not filter any entries.
  >
  > In the future, `init/2` will accept options for all of these to setup the reader / writer in the appropriate modes
  """
  def init(%__MODULE__{} = archive, _opts \\ []) do
    with {:ok, ref} <- Nif.safe_call(&Nif.archive_read_new/0),
         :ok <- Nif.safe_call(fn -> Nif.archive_read_support_filter_all(ref) end),
         :ok <- Nif.safe_call(fn -> Nif.archive_read_support_format_all(ref) end),
         :ok,
         Nif.safe_call(fn -> Nif.archive_read_support_format_raw(ref) end) do
      {:ok, %{archive | ref: ref}}
    end
  end

  def init!(%__MODULE__{} = archive, opts \\ []), do: init(archive, opts) |> unwrap!()

  defp stream_archive(init_fn, fun) do
    Stream.resource(
      init_fn,
      fn
        {%Archive{} = archive, has_info} ->
          with :ok <-
                 Nif.safe_call(
                   fn ->
                     Nif.archive_read_next_header(archive.ref, archive.entry_ref)
                   end,
                   archive.ref
                 ),
               {:ok, pathname} <-
                 Nif.safe_call(fn -> Nif.archive_entry_pathname(archive.entry_ref) end),
               {:ok, zig_stat} <-
                 Nif.safe_call(fn -> Nif.archive_entry_stat(archive.entry_ref) end),
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
        {{:error, _reason}, %Archive{ref: ref}} ->
          :ok = Archive.Nif.archive_read_close(ref)

        %Archive{ref: ref} ->
          :ok = Archive.Nif.archive_read_close(ref)
      end
    )
  end

  @doc """
  Streams the contents of an archive from a file, applying the supplied function to each entry.

  Refer to `read/3` for more information about the supplied function.
  """
  def from_file_streaming(%Archive{ref: nil} = archive, filename, fun)
      when is_binary(filename)
      when is_function(fun, 2) or is_function(fun, 1) do
    init_fn = fn ->
      with true <- File.regular?(filename),
           {:ok, %Archive{ref: ref} = archive} <- init(archive),
           :ok <-
             Nif.safe_call(
               fn ->
                 Nif.archive_read_open_filename(ref, filename, 10240)
               end,
               archive.ref
             ) do
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

  def from_file_streaming(%Archive{}, _, _),
    do: {:error, "You must use a new archive with `Archive.new/0`"}

  @doc """
  Streams the contents of an archive from memory, applying the supplied function to each entry.

  Refer to `read/3` for more information about the supplied function.
  """
  def from_memory_streaming(%Archive{ref: nil} = archive, data, fun)
      when is_binary(data)
      when is_function(fun, 2) or is_function(fun, 1) do
    init_fn = fn ->
      with {:ok, %Archive{ref: ref} = archive} <- init(archive),
           :ok <-
             Nif.safe_call(
               fn ->
                 Nif.archive_read_open_memory(ref, data)
               end,
               archive.ref
             ) do
        {archive, false}
      else
        {:error, error} ->
          {:error, error}
      end
    end

    stream_archive(init_fn, fun)
  end

  def from_memory_streaming(%Archive{}, _, _),
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
              entries: if(opts[:as] == :map, do: hierarchical(entries), else: entries)
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

  @doc """
  Converts a list of `Archive.Entry` to a hierachical map, similar to a filesystem structure.
  """
  def hierarchical(entries) when is_list(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      insert_entry(acc, String.split(entry.path, "/", trim: true), entry)
    end)
  end

  def hierarchical(_), do: %{}

  defp insert_entry(map, [], _entry), do: map

  defp insert_entry(map, [name], entry) do
    if is_directory?(entry) do
      Map.put_new(map, name, %{})
    else
      Map.put(map, name, entry)
    end
  end

  defp insert_entry(map, [dir | rest], entry) do
    Map.update(map, dir, insert_entry(%{}, rest, entry), &insert_entry(&1, rest, entry))
  end

  defp is_directory?(%Archive.Entry{stat: %File.Stat{type: :directory}}), do: true

  defp is_directory?(_), do: false

  @doc false
  def format_size(size) when is_integer(size) do
    cond do
      size < 1024 -> "#{size} B"
      size < 1024 * 1024 -> "#{Float.round(size / 1024, 2)} KB"
      size < 1024 * 1024 * 1024 -> "#{Float.round(size / (1024 * 1024), 2)} MB"
      true -> "#{Float.round(size / (1024 * 1024 * 1024), 2)} GB"
    end
  end

  def format_size(_), do: "unknown size"

  defimpl Inspect, for: Archive do
    import Inspect.Algebra

    @default_depth 3
    @default_breadth 2

    def inspect(%Archive{entries: entries, description: desc}, opts) do
      entries = if is_map(entries), do: entries, else: Archive.hierarchical(entries)
      depth = opts.custom_options[:depth] || @default_depth
      breadth = opts.custom_options[:breadth] || @default_breadth

      format_str = if desc, do: "[#{desc}]", else: ""

      cond do
        is_nil(entries) || entries == [] || entries == %{} ->
          concat(["#Archive", format_str, "<", color("initialized", :yellow, opts), ">"])

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
              color(Archive.format_size(summary.total_size), :magenta, opts)
            ])

          separator = color(String.duplicate("─", 15), :grey, opts)
          tree = build_tree(entries, depth, breadth, 1, opts)

          concat([
            "#Archive",
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
        color(Archive.format_size(size), :cyan, opts),
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
        color(Archive.format_size(summary.total_size), :cyan, opts),
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
