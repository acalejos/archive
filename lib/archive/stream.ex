defmodule Archive.Stream do
  @moduledoc """
  A reusable, lazy archive descriptor implementing `Enumerable` and `Collectable`.

  Enumeration opens a fresh reader and closes it on completion, halt, or error.
  Entries contain metadata; their bodies are consumed only when requested or
  when passed directly to a writer. Collection writes headers and bodies and
  finalizes the archive on `:done`. Each operation owns its own native handles.

      source = Archive.reader!("input.tar.gz")
      source
      |> Stream.reject(&String.ends_with?(&1.path, ".tmp"))
      |> Enum.into(Archive.writer!("output.zip", format: :zip))

  Read entry bodies inside the enumeration callback. `Archive.Entry.data_stream/2`
  provides bounded chunks, and the collector copies unread bodies automatically.
  Unloaded entries cannot be read after advancing to another entry or closing
  the enumeration. The same descriptor can be enumerated again or concurrently.
  """
  use Archive.Nif
  use Archive.Schemas, only: [:stream_schema]
  defstruct [:writer, :reader, :entry_ref]
  @type t :: %__MODULE__{reader: map() | nil, writer: map() | nil, entry_ref: reference() | nil}

  @doc "Creates a validated descriptor. No files are opened until consumption."
  def new(opts \\ []) do
    with {:ok, params} <- NimbleOptions.validate(opts, @stream_schema) do
      {:ok,
       %__MODULE__{
         reader: config(params[:reader], :read),
         writer: config(params[:writer], :write)
       }}
    end
  end

  defp config(false, _), do: nil

  defp config(opts, :read) do
    opts
    |> Map.new()
    |> Map.update!(:formats, &expand(&1, @read_formats -- [:raw]))
    |> Map.update!(:filters, &expand(&1, @read_filters))
    |> then(fn reader ->
      if reader.as == :auto do
        %{reader | as: if(File.regular?(reader.open), do: :file, else: :data)}
      else
        reader
      end
    end)
  end

  defp config(opts, :write) do
    opts |> Map.new() |> Map.update!(:filters, &expand(&1, @write_filters))
  end

  defp expand(:all, all), do: all
  defp expand([only: values], _), do: values
  defp expand([except: values], all), do: all -- values
  defp expand(values, _) when is_list(values), do: values
  defp expand(value, _), do: [value]

  @doc "Allocates and configures native handles. Prefer protocol consumption for automatic cleanup."
  def init(%__MODULE__{} = descriptor) do
    entry = Nif.archive_entry_new()
    reader = if descriptor.reader, do: Map.put(descriptor.reader, :ref, Nif.archive_read_new())
    writer = if descriptor.writer, do: Map.put(descriptor.writer, :ref, Nif.archive_write_new())
    active = %{descriptor | entry_ref: entry, reader: reader, writer: writer}

    try do
      if reader do
        Enum.each(
          reader.formats,
          &checked(
            fn ->
              Nif.archive_read_support_format_by_code(reader.ref, Nif.archiveFormatToInt(&1))
            end,
            reader.ref
          )
        )

        Enum.each(
          reader.filters,
          &checked(
            fn ->
              Nif.archive_read_support_filter_by_code(reader.ref, Nif.archiveFilterToInt(&1))
            end,
            reader.ref
          )
        )

        if reader[:options],
          do:
            checked(
              fn -> Nif.archive_read_set_options(reader.ref, reader.options) end,
              reader.ref
            )

        Enum.each(
          reader.passphrases,
          &checked(fn -> Nif.archive_read_add_passphrase(reader.ref, &1) end, reader.ref)
        )
      end

      if writer do
        checked(
          fn ->
            Nif.archive_write_set_format(writer.ref, Nif.archiveFormatToInt(writer.format))
          end,
          writer.ref
        )

        Enum.each(
          writer.filters,
          &checked(
            fn -> Nif.archive_write_add_filter(writer.ref, Nif.archiveFilterToInt(&1)) end,
            writer.ref
          )
        )

        if writer[:options],
          do:
            checked(
              fn -> Nif.archive_write_set_options(writer.ref, writer.options) end,
              writer.ref
            )

        if writer[:passphrase],
          do:
            checked(
              fn -> Nif.archive_write_set_passphrase(writer.ref, writer.passphrase) end,
              writer.ref
            )
      end

      {:ok, active}
    rescue
      e ->
        close(active)
        {:error, e}
    end
  end

  def init!(descriptor), do: init(descriptor) |> unwrap!()

  @doc false
  def checked(fun, ref), do: Nif.safe_call(fun, ref) |> unwrap!()

  @doc "Closes handles allocated by `init/1`. Protocol consumption closes automatically."
  def close(%__MODULE__{} = active) do
    if active.reader && active.reader[:ref],
      do: Nif.safe_call(fn -> Nif.archive_read_free(active.reader.ref) end)

    if active.writer && active.writer[:ref],
      do: Nif.safe_call(fn -> Nif.archive_write_free(active.writer.ref) end)

    if active.entry_ref, do: Nif.archive_entry_free(active.entry_ref)
    :ok
  end

  @doc false
  def open_reader(descriptor) do
    active = init!(%{descriptor | writer: nil})

    try do
      r = active.reader

      checked(
        fn ->
          if r.as == :file,
            do: Nif.archive_read_open_filename(r.ref, r.open, r.block_size),
            else: Nif.archive_read_open_memory(r.ref, r.open)
        end,
        r.ref
      )

      active
    rescue
      e ->
        close(active)
        reraise e, __STACKTRACE__
    end
  end

  @doc false
  def with_reader(descriptor, fun) do
    active = open_reader(descriptor)

    try do
      entries =
        Stream.unfold(active, fn active ->
          case next_entry(active) do
            {:halt, _} -> nil
            {[entry], next} -> {entry, next}
          end
        end)

      fun.(entries, active.reader.ref)
    after
      close(active)
    end
  end

  @doc false
  def next_entry(active) do
    case Nif.safe_call(fn ->
           Nif.archive_read_next_header(active.reader.ref, active.entry_ref)
         end) do
      :ok ->
        entry = Archive.Entry.new!() |> Archive.Entry.read_header(active) |> unwrap!()
        {[entry], active}

      {:error, :ArchiveEof} ->
        {:halt, active}

      {:error, reason} ->
        raise Archive.Error,
          reason: Nif.get_error_string(active.reader.ref) || reason,
          action: "read",
          path: active.reader.open
    end
  end

  @doc false
  def open_writer(descriptor) do
    active = init!(%{descriptor | reader: nil})

    try do
      checked(
        fn -> Nif.archive_write_open_filename(active.writer.ref, active.writer.file) end,
        active.writer.ref
      )

      {active,
       fn
         acc, {:cont, %Archive.Entry{} = entry} ->
           Archive.Entry.write!(entry, acc)
           acc

         acc, :done ->
           try do
             checked(fn -> Nif.archive_write_close(acc.writer.ref) end, acc.writer.ref)
             descriptor
           after
             close(acc)
           end

         acc, :halt ->
           Nif.safe_call(fn -> Nif.archive_write_fail(acc.writer.ref) end)
           close(acc)
       end}
    rescue
      e ->
        close(active)
        reraise e, __STACKTRACE__
    end
  end

  defimpl Enumerable do
    def reduce(%{reader: nil}, _, _), do: raise(ArgumentError, "stream has no reader")

    def reduce(descriptor, acc, fun) do
      Stream.resource(
        fn -> Archive.Stream.open_reader(descriptor) end,
        &Archive.Stream.next_entry/1,
        &Archive.Stream.close/1
      ).(acc, fun)
    end

    def count(_), do: {:error, __MODULE__}
    def member?(_, _), do: {:error, __MODULE__}
    def slice(_), do: {:error, __MODULE__}
  end

  defimpl Collectable do
    def into(%{writer: nil}), do: raise(ArgumentError, "stream has no writer")
    def into(descriptor), do: Archive.Stream.open_writer(descriptor)
  end

  defimpl Inspect do
    def inspect(stream, opts) do
      parts =
        [
          stream.reader &&
            "r#{if stream.reader.as == :file, do: Kernel.inspect(stream.reader.open), else: ":raw"}[#{Enum.join(stream.reader.formats, ",")}]",
          stream.writer &&
            "w#{Kernel.inspect(stream.writer.file)}[#{stream.writer.format}:#{Enum.join(stream.writer.filters, ",")}]"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")

      Inspect.Algebra.string("#Archive.Stream<#{parts}>") |> Inspect.Algebra.color(:map, opts)
    end
  end
end
