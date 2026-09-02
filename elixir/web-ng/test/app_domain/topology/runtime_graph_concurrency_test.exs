defmodule ServiceRadarWebNG.Topology.RuntimeGraphConcurrencyTest do
  # async: false -- these tests suspend the shared RuntimeGraph process. ExUnit runs sync
  # modules serially, after every async module has finished, so nothing else is reading the
  # graph while it is held.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Topology.RuntimeGraph

  @moduletag :db_free

  # The DB-free tier runs with `--no-start` (see Mix.Tasks.Serviceradar.MaybeTest), so the
  # supervised process only exists in the DB-backed tier. Start one here when it is absent
  # rather than asserting either shape -- a `start_supervised!` of an app-owned name blows
  # up wherever the app IS running, and a bare `whereis` skips the whole point wherever it
  # is not.
  setup do
    pid =
      case Process.whereis(RuntimeGraph) do
        nil -> start_supervised!(RuntimeGraph)
        pid when is_pid(pid) -> pid
      end

    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)

    {:ok, pid: pid}
  end

  describe "reads do not queue behind the refresh handler" do
    test "get_links/0 answers while the owning process is blocked", %{pid: pid} do
      # A suspended process stands in for `handle_info(:refresh, ...)`, which performs the
      # projection/AGE round trip inline. Routed through `GenServer.call/2` this waits out
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
end
