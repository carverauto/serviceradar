defmodule ServiceRadarWebNG.Topology.RuntimeSupervisionTest do
  # Dashboard topology links, GodViewStream link edges and the snapshot
  # revisions endpoint call RuntimeGraph and AtlasStore by name, so the
  # application supervision tree -- not a per-test manual start -- must keep
  # them running.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Topology.AtlasStore
  alias ServiceRadarWebNG.Topology.RuntimeGraph
  alias ServiceRadarWebNG.Topology.RuntimeSupervisor

  @moduletag :web_ng_shared_fixture_db

  test "application supervision runs the atlas store and runtime graph" do
    child_ids =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(ServiceRadarWebNG.Supervisor) do
        id
      end

    assert RuntimeSupervisor in child_ids
    assert is_pid(Process.whereis(RuntimeSupervisor))
    assert is_pid(Process.whereis(RuntimeGraph))
    assert is_pid(Process.whereis(AtlasStore))
    assert {:ok, links} = RuntimeGraph.get_links()
    assert is_list(links)
  end
end
