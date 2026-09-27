defmodule ServiceRadarWebNG.Topology.RuntimeGraphConcurrencyTest do
  # async: false -- these tests suspend the shared RuntimeGraph process. ExUnit runs sync
  # modules serially, after every async module has finished, so nothing else is reading the
  # graph while it is held.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Topology.Atlas
  alias ServiceRadarWebNG.Topology.AtlasReader
  alias ServiceRadarWebNG.Topology.AtlasStore
  alias ServiceRadarWebNG.Topology.RuntimeGraph
  alias ServiceRadarWebNG.Topology.RuntimeSupervisor

  @moduletag :db_free

  # The DB-free tier runs with `--no-start` (see Mix.Tasks.Serviceradar.MaybeTest), so the
  # supervised process only exists in the DB-backed tier. Start one here when it is absent
  # rather than asserting either shape -- a `start_supervised!` of an app-owned name blows
  # up wherever the app IS running, and a bare `whereis` skips the whole point wherever it
  # is not.
  setup do
    if is_nil(Process.whereis(RuntimeSupervisor)), do: start_supervised!(RuntimeSupervisor)
    pid = Process.whereis(RuntimeGraph)

    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)

    {:ok, pid: pid}
  end

  describe "reads do not queue behind the refresh handler" do
    test "get_links/0 answers while the owning process is blocked", %{pid: pid} do
      # A suspended process stands in for `handle_info(:refresh, ...)`, which performs the
      # Dgraph round trip inline. Routed through `GenServer.call/2` this waits out
      # the default 5s and exits; reading the published reference does not touch the process.
      :sys.suspend(pid)

      assert {:ok, links} = RuntimeGraph.get_links()
      assert is_list(links)
    end

    test "get_graph_ref/0 answers while the owning process is blocked", %{pid: pid} do
      :sys.suspend(pid)

      assert {:ok, graph_ref} = RuntimeGraph.get_graph_ref()
      assert graph_ref
    end

    test "the published reference is the one the process owns", %{pid: pid} do
      {:ok, published} = RuntimeGraph.get_graph_ref()
      %{graph_ref: owned} = :sys.get_state(pid)

      assert published === owned
    end
  end

  test "store loss restarts its producer", %{pid: producer} do
    monitor = Process.monitor(producer)
    store = Process.whereis(AtlasStore)
    :sys.suspend(store)
    on_exit(fn -> if Process.alive?(store), do: :sys.resume(store) end)

    requester = self()
    request = make_ref()
    {caller, caller_monitor} = spawn_monitor(fn -> send(requester, {request, AtlasReader.fetch(nil)}) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    await_queued_fetch(store, caller)
    Process.exit(store, :kill)

    assert_receive {^request, {:error, :unavailable}}, 2_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 2_000

    assert_receive {:DOWN, ^monitor, :process, ^producer, :shutdown}, 1_000

    children = replaced_children(%{RuntimeGraph => producer, AtlasStore => store})
    assert is_pid(children[RuntimeGraph])
    assert is_pid(children[AtlasStore])
    refute children[RuntimeGraph] == producer
    refute children[AtlasStore] == store
  end

  test "producer loss retains the last published level", %{pid: producer} do
    {:ok, atlas} = Atlas.build([%{id: "host01.example.com"}], [])
    :ok = AtlasStore.publish(atlas)
    {:ok, level} = AtlasStore.fetch()
    store = Process.whereis(AtlasStore)
    monitor = Process.monitor(producer)
    Process.exit(producer, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^producer, :killed}, 1_000
    children = replaced_children(%{RuntimeGraph => producer})
    refute children[RuntimeGraph] == producer
    assert children[AtlasStore] == store
    assert {:ok, ^level} = AtlasStore.fetch()
  end

  defp await_queued_fetch(store, caller, attempts \\ 200) do
    {:messages, messages} = Process.info(store, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", {^caller, _tag}, {:fetch, "global"}}, &1)) do
      :ok
    else
      if attempts == 0, do: flunk("reader did not queue its fetch before the store failure")
      Process.sleep(10)
      await_queued_fetch(store, caller, attempts - 1)
    end
  end

  defp replaced_children(previous, attempts \\ 100) do
    children =
      RuntimeSupervisor
      |> Supervisor.which_children()
      |> Map.new(fn {id, pid, _type, _modules} -> {id, pid} end)

    if Enum.all?(previous, fn {id, pid} -> is_pid(children[id]) and children[id] != pid end) do
      children
    else
      if attempts == 0, do: flunk("supervisor did not replace the expected children")
      Process.sleep(10)
      replaced_children(previous, attempts - 1)
    end
  end
end
