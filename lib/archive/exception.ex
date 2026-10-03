defmodule Archive.Error do
  alias Archive.Nif
  defexception [:reason, :path, action: ""]

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  @impl true
  def message(%{action: action, reason: reason, path: path}) do
    zlib_version_string = Nif.archive_zlib_version()
    liblzma_version_string = Nif.archive_liblzma_version()
    bzlib_version_string = Nif.archive_bzlib_version()
    liblz4_version_string = Nif.archive_liblz4_version()
    libzstd_version_string = Nif.archive_libzstd_version()

    """
    could not #{action} #{inspect(path)}: #{format_reason(reason)}

        libarchive details:
          > zlib: #{zlib_version_string || "not loaded"}
          > liblzma: #{liblzma_version_string || "not loaded"}
          > bzlib: #{bzlib_version_string || "not loaded"}
          > liblz4: #{liblz4_version_string || "not loaded"}
          > libzstd: #{libzstd_version_string || "not loaded"}
    """
  end
end
