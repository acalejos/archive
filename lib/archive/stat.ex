defmodule Archive.Stat do
  require Archive.Nif
  import Bitwise

  @file_kinds Archive.Nif.get_file_kinds() |> Map.drop([:mask])
  @mask Archive.Nif.get_file_kinds() |> Map.get(:mask)
  @lookup Enum.into(@file_kinds, %{}, fn {k, v} -> {v, k} end)

  def file_kinds(), do: @file_kinds

  def file_stat_to_zig_map(%File.Stat{} = stat) do
    %{
      ino: convert_integer(stat.inode),
      size: convert_integer(stat.size),
      mode: convert_integer(stat.mode),
      nlink: convert_integer(stat.links),
      gid: convert_integer(stat.gid),
      uid: convert_integer(stat.uid)
    }
    |> Map.merge(to_zig_timespec(stat))
    |> Map.merge(to_zig_device(stat))
  end

  defp to_zig_device(%{major_device: devmajor, minor_device: devminor}) do
    %{dev: combine_major_minor(devmajor, devminor)}
  end

  defp to_zig_timespec(%File.Stat{atime: atime, mtime: mtime, ctime: ctime}) do
    case :os.type() do
      {:unix, :darwin} ->
        %{
          atimespec: %{tv_sec: extract_seconds(atime), tv_nsec: extract_nanoseconds(atime)},
          mtimespec: %{tv_sec: extract_seconds(mtime), tv_nsec: extract_nanoseconds(mtime)},
          ctimespec: %{tv_sec: extract_seconds(ctime), tv_nsec: extract_nanoseconds(ctime)},
          # These are required since it checks for type on the parameter
          # these correspond to std.c.darwin's stat
          birthtimespec: %{tv_sec: 0, tv_nsec: 0},
          rdev: 0,
          blocks: 0,
          blksize: 0,
          flags: 0,
          gen: 0,
          lspare: 0,
          qspare: [0, 0]
        }

      {:unix, _} ->
        %{
          atim: %{sec: extract_seconds(atime), nsec: extract_nanoseconds(atime)},
          mtim: %{sec: extract_seconds(mtime), nsec: extract_nanoseconds(mtime)},
          ctim: %{sec: extract_seconds(ctime), nsec: extract_nanoseconds(ctime)},
          rdev: 0,
          blksize: 0,
          blocks: 0
        }
    end
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

  defp extract_nanoseconds(:undefined), do: 0
  # Calendar format doesn't include nanoseconds
  defp extract_nanoseconds({{_, _, _}, {_, _, _}}), do: 0
  # For integer timestamps, we don't have nanosecond precision
  defp extract_nanoseconds(_), do: 0

  @doc false
  def to_file_stat(zig_stat) do
    %File.Stat{
      access: get_access(zig_stat.mode),
      gid: zig_stat.gid,
      inode: zig_stat.ino,
      links: zig_stat.nlink,
      mode: zig_stat.mode,
      size: zig_stat.size,
      uid: zig_stat.uid
    }
    |> struct!(convert_time(zig_stat))
    |> struct!(major_minor(zig_stat))
    |> struct!(convert_type(zig_stat))
  end

  def major_minor(%{dev: dev}) when is_integer(dev) do
    # On most Unix-like systems:
    # - major = dev >> 8
    # - minor = dev & 0xFF
    # However, this can vary by OS. Here's a more portable approach:
    major = div(dev, 256)
    minor = rem(dev, 256)

    %{major_device: major, minor_device: minor}
  end

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

  defp convert_time(%{atime: atime, mtime: mtime, ctime: ctime}) do
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
