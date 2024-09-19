defmodule Archive.Format do
  @moduledoc false
  import Bitwise

  @base_mask 0xFF0000

  @cpio 0x10000
  @shar 0x20000
  @tar 0x30000
  @iso9660 0x40000
  @zip 0x50000
  @empty 0x60000
  @ar 0x70000
  @mtree 0x80000
  @raw 0x90000
  @xar 0xA0000
  @lha 0xB0000
  @cab 0xC0000
  @rar 0xD0000
  @sevenz 0xE0000
  @warc 0xF0000
  @rar_v5 0x100000

  def to_atom(format) do
    cond do
      format == @base_mask -> :base_mask
      format == @cpio -> :cpio
      format == (@cpio ||| 1) -> :cpio_posix
      format == (@cpio ||| 2) -> :cpio_bin_le
      format == (@cpio ||| 3) -> :cpio_bin_be
      format == (@cpio ||| 4) -> :cpio_svr4_nocrc
      format == (@cpio ||| 5) -> :cpio_svr4_crc
      format == (@cpio ||| 6) -> :cpio_afio_large
      format == (@cpio ||| 7) -> :cpio_pwb
      format == @shar -> :shar
      format == (@shar ||| 1) -> :shar_base
      format == (@shar ||| 2) -> :shar_dump
      format == @tar -> :tar
      format == (@tar ||| 1) -> :tar_ustar
      format == (@tar ||| 2) -> :tar_pax_interchange
      format == (@tar ||| 3) -> :tar_pax_restricted
      format == (@tar ||| 4) -> :tar_gnutar
      format == @iso9660 -> :iso9660
      format == (@iso9660 ||| 1) -> :iso9660_rockridge
      format == @zip -> :zip
      format == @empty -> :empty
      format == @ar -> :ar
      format == (@ar ||| 1) -> :ar_gnu
      format == (@ar ||| 2) -> :ar_bsd
      format == @mtree -> :mtree
      format == @raw -> :raw
      format == @xar -> :xar
      format == @lha -> :lha
      format == @cab -> :cab
      format == @rar -> :rar
      format == @sevenz -> :sevenz
      format == @warc -> :warc
      format == @rar_v5 -> :rar_v5
      true -> :unknown
    end
  end

  def format_size(size) when is_integer(size) do
    cond do
      size < 1024 -> "#{size} B"
      size < 1024 * 1024 -> "#{Float.round(size / 1024, 2)} KB"
      size < 1024 * 1024 * 1024 -> "#{Float.round(size / (1024 * 1024), 2)} MB"
      true -> "#{Float.round(size / (1024 * 1024 * 1024), 2)} GB"
    end
  end

  def format_size(_), do: "unknown size"
end
