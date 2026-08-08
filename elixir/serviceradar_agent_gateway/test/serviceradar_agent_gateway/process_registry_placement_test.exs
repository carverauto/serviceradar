defmodule ServiceRadarAgentGateway.ProcessRegistryPlacementTest do
  @moduledoc """
  Pins the gateway's Horde placement posture: the gateway stays in the process
  registry CRDT mesh (it writes the control-stream/agent entries core reads)
  but must never host distributed processes — it runs without the core Repo,
  so a StatefulAlertEngine shard placed here would load zero alert rules.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.ProcessRegistry

  @moduletag :requires_app

  test "gateway does not host Horde-distributed processes" do
    refute ProcessRegistry.host_distributed_processes?()
  end

  test "gateway stays in the process registry mesh" do
    assert ProcessRegistry.join_process_registry?()
  end

  test "start_child refuses placement on this node" do
    child_spec = %{
      id: :placement_probe,
      start: {Task, :start_link, [fn -> :ok end]},
      restart: :temporary
    }

    assert {:error, :not_a_process_host} = ProcessRegistry.start_child(child_spec)
  end
end
