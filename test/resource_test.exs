defmodule Archive.ResourceTest do
  use ExUnit.Case, async: true
  alias Archive.Nif, as: N

  defp stats(probe), do: N.archive_resource_stats(probe).freed
  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp receive_from(fun) do
    parent = self()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {:result, fun.()}) end)
    result = receive do: ({:result, value} -> value)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    result
  end

  test "GC releases each native resource once without explicit free" do
    for constructor <- [
          :archive_read_new,
          :archive_write_new,
          :archive_match_new,
          :archive_entry_new,
          :archive_entry_linkresolver_new
        ] do
      probe = receive_from(fn -> N.archive_resource_probe(apply(N, constructor, [])) end)
      eventually(fn -> stats(probe) == 1 end)
      assert stats(probe) == 1
    end
  end

  test "explicit free is idempotent across aliases and GC" do
    probe =
      receive_from(fn ->
        entry = N.archive_entry_new()
        alias_entry = entry
        probe = N.archive_resource_probe(entry)
        assert :ok = N.archive_entry_free(entry)
        assert :ok = N.archive_entry_free(alias_entry)
        assert_raise ErlangError, fn -> N.archive_entry_pathname(alias_entry) end
        probe
      end)

    eventually(fn -> stats(probe) == 1 end)
  end

  test "a killed process releases its native readers" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        reader = N.archive_read_new()
        send(parent, {:probe, N.archive_resource_probe(reader)})
        receive do: (:stop -> N.archive_read_free(reader))
      end)

    assert_receive {:probe, probe}
    assert stats(probe) == 0
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    eventually(fn -> stats(probe) == 1 end)
  end

  test "new2 entries retain their original archive until released" do
    {entry, probe} =
      receive_from(fn ->
        writer = N.archive_write_new()
        entry = N.archive_entry_new2(writer)
        N.archive_entry_set_pathname(entry, "retained")
        {entry, N.archive_resource_probe(writer)}
      end)

    assert stats(probe) == 0
    assert N.archive_entry_pathname(entry) == "retained"
    N.archive_entry_free(entry)
    eventually(fn -> stats(probe) == 1 end)
  end

  test "clearing an entry safely detaches an explicitly freed archive" do
    writer = N.archive_write_new()
    entry = N.archive_entry_new2(writer)
    N.archive_write_free(writer)
    assert_raise ErlangError, fn -> N.archive_entry_pathname(entry) end
    assert :ok = N.archive_entry_clear(entry)
    assert :ok = N.archive_entry_set_pathname(entry, "reused")
    assert N.archive_entry_pathname(entry) == "reused"
    N.archive_entry_free(entry)
  end

  test "concurrent frees serialize and destroy the allocation once" do
    reader = N.archive_read_new()
    probe = N.archive_resource_probe(reader)
    tasks = for _ <- 1..20, do: Task.async(fn -> N.archive_read_free(reader) end)
    assert Enum.map(tasks, &Task.await/1) == List.duplicate(:ok, 20)
    assert stats(probe) == 1
  end

  test "clones have independent native ownership" do
    original = N.archive_entry_new()
    N.archive_entry_set_pathname(original, "before")
    clone = N.archive_entry_clone(original)
    probe = N.archive_resource_probe(clone)
    N.archive_entry_free(original)
    assert N.archive_entry_pathname(clone) == "before"
    assert stats(probe) == 0
    N.archive_entry_free(clone)
    assert stats(probe) == 1
  end

  test "wrong free functions reject resource types without freeing them" do
    writer = N.archive_write_new()
    probe = N.archive_resource_probe(writer)
    assert_raise ErlangError, fn -> N.archive_read_free(writer) end
    assert_raise ErlangError, fn -> N.archive_match_free(writer) end
    assert stats(probe) == 0
    N.archive_write_free(writer)
    assert stats(probe) == 1
  end

  test "platform typedefs preserve their C signedness" do
    entry = N.archive_entry_new()

    if :os.type() == {:unix, :darwin} do
      assert :ok = N.archive_entry_set_dev(entry, -1)
      assert N.archive_entry_dev(entry) == -1
    else
      assert_raise ErlangError, fn -> N.archive_entry_set_dev(entry, -1) end
    end

    # Libarchive 3.x uses a signed inode argument; negative values unset it.
    N.archive_entry_set_ino(entry, 42)
    assert :ok = N.archive_entry_set_ino(entry, -1)
    assert N.archive_entry_ino_is_set(entry) == 0
    N.archive_entry_free(entry)
  end

  test "portable stat maps retain sizes larger than the Windows CRT stat field" do
    entry = N.archive_entry_new()
    size = 8_589_934_592
    N.archive_entry_set_size(entry, size)
    stat = N.archive_entry_stat(entry)
    assert stat.size == size
    copy = N.archive_entry_new()
    assert :ok = N.archive_entry_copy_stat(copy, stat)
    assert N.archive_entry_size(copy) == size
    assert N.archive_entry_stat(copy).size == size
    N.archive_entry_free(entry)
    N.archive_entry_free(copy)
  end

  test "memory input survives its producing process and chunks survive advancement" do
    {reader, header} =
      receive_from(fn ->
        writer = N.archive_write_new()
        N.archive_write_set_format_pax_restricted(writer)
        N.archive_write_set_bytes_per_block(writer, 0)
        N.archive_write_open_memory(writer, 4096)
        entry = N.archive_entry_new()
        N.archive_entry_set_pathname(entry, "body")
        N.archive_entry_set_mode(entry, 0o100644)
        N.archive_entry_set_size(entry, 6)
        N.archive_write_header(writer, entry)
        N.archive_write_data(writer, "abcdef")
        N.archive_write_close(writer)
        bytes = N.archive_write_memory(writer)
        reader = N.archive_read_new()
        N.archive_read_support_format_all(reader)
        N.archive_read_open_memory(reader, bytes)
        header = N.archive_entry_new()
        N.archive_read_next_header2(reader, header)
        {reader, header}
      end)

    generation = N.archive_read_generation(reader)
    assert N.archive_entry_read_generation(header) == generation
    chunk = N.archive_read_data_current(reader, generation, 3)
    assert chunk == "abc"
    assert N.archive_read_data_current(reader, generation, 3) == "def"
    assert N.archive_read_data_current(reader, generation, 3) == ""
    assert_raise ErlangError, fn -> N.archive_read_next_header2(reader, header) end
    assert_raise ErlangError, fn -> N.archive_read_data_current(reader, generation, 3) end
    N.archive_read_free(reader)
    N.archive_entry_free(header)
    assert chunk == "abc"
  end
end
