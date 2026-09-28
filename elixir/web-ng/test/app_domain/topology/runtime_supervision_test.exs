defmodule ServiceRadarWebNG.Topology.RuntimeSupervisionTest do
  # Dashboard topology links and GodViewStream link edges call RuntimeGraph by
  # name, so the application supervision tree -- not a per-test manual start --
  # must keep it running.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Topology.RuntimeGraph

  @moduletag :web_ng_shared_fixture_db

  test "application supervision runs the runtime topology graph" do
    child_ids =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(ServiceRadarWebNG.Supervisor) do
        id
      end

    assert RuntimeGraph in child_ids
    assert is_pid(Process.whereis(RuntimeGraph))
    assert {:ok, links} = RuntimeGraph.get_links()
    assert is_list(links)
  end
end
