defmodule Archive.Stat do
  require Archive.Nif
  import Bitwise

  @file_kinds Archive.Nif.get_file_kinds() |> Map.drop([:mask])
  @mask Archive.Nif.get_file_kinds() |> Map.get(:mask)
  @lookup @file_kinds
          |> Map.put(:regular, @file_kinds.file)
          |> Map.delete(:file)
          |> Map.delete(:unknown)
          |> Map.put(:symlink, @file_kinds.sym_link)
          |> Map.delete(:sym_link)
          |> Map.put(:device, @file_kinds.character_device)
          |> Map.delete(:character_device)
          |> Enum.into(%{}, fn {k, v} -> {v, k} end)

  def file_kinds(), do: @file_kinds

  def file_stat_to_native_map(%File.Stat{} = stat) do
    %{
      ino: convert_integer(stat.inode),
      size: convert_integer(stat.size),
      mode: convert_integer(stat.mode),
      nlink: convert_integer(stat.links),
      gid: convert_integer(stat.gid),
      uid: convert_integer(stat.uid)
    }
    |> Map.merge(to_native_timespec(stat))
    |> Map.merge(to_native_device(stat))
  end

  defp to_native_device(%{major_device: devmajor, minor_device: devminor}) do
    # File.Stat uses these names for st_dev and st_rdev, not split device bits.
    %{dev: convert_integer(devmajor), rdev: convert_integer(devminor)}
  end

  defp to_native_timespec(%File.Stat{atime: atime, mtime: mtime, ctime: ctime}) do
    %{
      atim: %{sec: extract_seconds(atime), nsec: 0},
      mtim: %{sec: extract_seconds(mtime), nsec: 0},
      ctim: %{sec: extract_seconds(ctime), nsec: 0}
    }
  end

  defp convert_integer(:undefined), do: 0
  defp convert_integer(value) when is_integer(value), do: value
  defp convert_integer(_), do: 0

  defp extract_seconds(:undefined), do: 0

  defp extract_seconds({{year, month, day}, {hour, minute, second}}) do
    :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}}) -
      62_167_219_200
  end

  defp extract_seconds(unix_timestamp) when is_integer(unix_timestamp), do: unix_timestamp
  defp extract_seconds(_), do: 0

  @doc false
  def to_file_stat(native_stat) do
    %File.Stat{
      access: get_access(native_stat.mode),
      gid: native_stat.gid,
      inode: native_stat.ino,
      links: native_stat.nlink,
      mode: native_stat.mode,
      size: native_stat.size,
      uid: native_stat.uid
    }
    |> struct!(convert_time(native_stat))
    |> struct!(major_minor(native_stat))
    |> struct!(convert_type(native_stat))
  end

  def major_minor(%{dev: dev, rdev: rdev}) when is_integer(dev) and is_integer(rdev),
    do: %{major_device: dev, minor_device: rdev}

  def major_minor(%{dev: dev}) when is_integer(dev),
    do: %{major_device: dev, minor_device: 0}

  def combine_major_minor(major, minor) when is_integer(major) and is_integer(minor) do
    # Ensure that major and minor are within valid ranges
    major = max(0, min(major, 255))
    minor = max(0, min(minor, 255))

    # Combine major and minor
    major * 256 + minor
  end

  defp get_access(mode) do
    cond do
      (mode &&& 0o600) == 0o600 -> :read_write
      (mode &&& 0o400) == 0o400 -> :read
      (mode &&& 0o200) == 0o200 -> :write
      true -> :none
    end
  end

  defp convert_time(%{atimespec: atime, mtimespec: mtime, ctimespec: ctime}) do
    %{
      atime: convert_time(atime),
      mtime: convert_time(mtime),
      ctime: convert_time(ctime)
    }
  end

  defp convert_time(%{atim: atime, mtim: mtime, ctim: ctime}) do
    %{
      atime: convert_time(atime),
      mtime: convert_time(mtime),
      ctime: convert_time(ctime)
    }
  end

  defp convert_time(%{tv_sec: sec, tv_nsec: nsec}), do: convert_time(sec, nsec)
  defp convert_time(%{sec: sec, nsec: nsec}), do: convert_time(sec, nsec)

  defp convert_time(sec, nsec) do
    DateTime.from_unix!(sec, :second)
    |> DateTime.add(nsec, :nanosecond)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
  end

  defp convert_type(%{mode: mode}) when is_integer(mode) do
    %{type: Map.get(@lookup, Bitwise.band(mode, @mask), :other)}
  end
end
