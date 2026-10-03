defmodule Archive.Nif do
  @moduledoc """
  Rustler bindings to bundled libarchive 3.8.9. See the [binding guide](bindings.md)
  for signatures, ownership, return conventions, and the complete API inventory.

  Handles are garbage-collected resources. Explicit `archive_*_free` calls are
  idempotent; using a freed handle raises `ErlangError`. Native calls run on dirty
  I/O schedulers and lock each resource in a consistent order. Strings are Elixir
  binaries (including the `_w` variants, which convert UTF-8 to native wchar_t).
  Pointer outputs become binaries, maps, or owned entry handles.

  Use `safe_call/2` to convert native errors into result tuples. It treats
  libarchive warnings as successful operations and logs their diagnostic.
  """
  require Logger

  for file <- [
        "scripts/build_native.py",
        "native/dependencies.json",
        "vendor/libarchive/archive.h",
        "vendor/libarchive/archive_entry.h"
      ] do
    @external_resource Path.expand("../../" <> file, __DIR__)
  end

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :archive,
    crate: "archive_nif",
    path: "native/archive",
    version: version,
    base_url:
      System.get_env("ARCHIVE_PRECOMPILED_BASE_URL") ||
        "https://github.com/acalejos/archive/releases/download/v#{version}",
    targets: [
      "x86_64-unknown-linux-gnu",
      "aarch64-unknown-linux-gnu",
      "x86_64-unknown-linux-musl",
      "aarch64-unknown-linux-musl",
      "x86_64-apple-darwin",
      "aarch64-apple-darwin",
      "x86_64-pc-windows-msvc",
      "aarch64-pc-windows-msvc"
    ],
    nif_versions: ["2.17"],
    force_build:
      System.get_env("ARCHIVE_BUILD") in ["1", "true"] ||
        Application.compile_env(:rustler_precompiled, [:force_build, :archive], false),
    cargo: {:rustup, "1.95.0"}

  @doc false
  def dispatch(_index, _args), do: :erlang.nif_error(:nif_not_loaded)

  @external_resource Path.expand("../../priv/bindings.exs", __DIR__)
  {bindings, _} = Code.eval_file(Path.expand("../../priv/bindings.exs", __DIR__))

  for {name, index, arity, signature} <- bindings do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc """
    Managed #{name}/#{arity} binding. See the binding guide for return values.

    Native parameters:

    ```text
    #{signature}
    ```
    """
    def unquote(name)(unquote_splicing(args)) do
      dispatch(unquote(index), [unquote_splicing(args)])
    end
  end

  @errors [:ArchiveEof, :ArchiveRetry, :ArchiveFailed, :ArchiveWarn, :ArchiveFatal]

  def get_error_string(ref) when is_reference(ref) do
    err_string = archive_error_string(ref)

    archive_clear_error(ref)

    err_string
  end

  def safe_call(fun, ref \\ nil) do
    try do
      case fun.() do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:ok, other}
      end
    rescue
      e in [ErlangError, ArgumentError] ->
        error_string =
          if ref do
            get_error_string(ref)
          end

        case e do
          %ArgumentError{} ->
            {:error, :argument_error}

          %{original: :ArchiveWarn} ->
            if error_string, do: Logger.debug(error_string)
            :ok

          %{original: error} when error in @errors ->
            {:error, error_string || error}

          %{original: reason} ->
            {:error, error_string || reason}
        end
    end
  end

  defmacro call(func) do
    quote do
      safe_call(fn -> unquote(func) end)
    end
  end

  defmacro call(func, ref) do
    quote do
      safe_call(fn -> unquote(func) end, unquote(ref))
    end
  end

  @doc false
  def unwrap!(:ok), do: :ok
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %_{} = reason}), do: raise(reason)
  def unwrap!({:error, reason}), do: raise(Archive.Error, reason: reason)
  def unwrap!(other), do: raise(ArgumentError, "expected a result, got: #{inspect(other)}")

  def list_all(:formats, :read), do: listReadableFormats() |> Enum.map(&String.to_atom/1)
  def list_all(:filters, :read), do: listReadableFilters() |> Enum.map(&String.to_atom/1)
  def list_all(:formats, :write), do: listWritableFormats() |> Enum.map(&String.to_atom/1)
  def list_all(:filters, :write), do: listWritableFilters() |> Enum.map(&String.to_atom/1)

  defmacro get_file_kinds() do
    file_types = fileKinds()

    quote do
      unquote(Macro.escape(file_types))
    end
  end

  defmacro __using__(_opts) do
    read_formats = list_all(:formats, :read)
    read_filters = list_all(:filters, :read)
    write_formats = list_all(:formats, :write)
    write_filters = list_all(:filters, :write)
    extract_info = getExtractInfo()

    quote do
      alias Archive.Nif
      import Archive.Nif, only: [unwrap!: 1, call: 1, call: 2, safe_call: 2, safe_call: 1]
      @read_formats unquote(read_formats)
      @read_filters unquote(read_filters)
      @write_formats unquote(write_formats)
      @write_filters unquote(write_filters)
      @extract_info unquote(Macro.escape(extract_info))
    end
  end
end
