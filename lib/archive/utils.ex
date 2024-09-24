defmodule Archive.Utils do
  use Archive.Schemas, only: [:extract_schema]
  import Bitwise, only: [bor: 2]
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
  def handle_extract_opts(opts \\ []) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @extract_schema) do
      flags =
        case opts[:flags] do
          flag when is_integer(flag) ->
            flag

          [] ->
            0

          [flag] ->
            Archive.Nif.extractFlagToInt(flag)

          [flag | rest] ->
            Enum.reduce(rest, flag, fn next, acc -> bor(acc, next) end)
        end

      destination = opts[:to]

      valid_dir =
        if destination do
          cond do
            File.dir?(destination) ->
              :ok

            File.regular?(destination) ->
              {:error, "Regular file found at #{inspect(destination)}"}

            true ->
              File.mkdir_p(destination)
          end
        else
          :ok
        end

      case valid_dir do
        :ok ->
          {:ok, Keyword.put(opts, :flags, flags)}

        error ->
          error
      end
    end
  end
end
