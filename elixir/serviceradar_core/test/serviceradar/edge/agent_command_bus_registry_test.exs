defmodule ServiceRadar.Edge.AgentCommandBusRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.ProcessRegistry

  defmodule Session do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, nil, name: opts[:name])

    @impl true
    def init(state), do: {:ok, state}
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:horde)

    if !Process.whereis(ProcessRegistry.registry_name()) do
      Enum.each(ProcessRegistry.child_specs(), fn child_spec -> start_supervised!(child_spec) end)
    end

    :ok
  end

  test "exact partition lookup selects the matching principal and agent-only lookup is ambiguous" do
    agent_id = "shared-agent-#{System.unique_integer([:positive])}"
    gateway_node = :gateway@shared

    farm_pid = start_session(agent_id, "farm01", gateway_node, :farm)
    tonka_pid = start_session(agent_id, "tonka01", gateway_node, :tonka)

    assert eventually(fn ->
             match?(
               {:ok, %{control_session_pid: ^farm_pid, partition_id: "farm01"}},
               AgentCommandBus.resolve_control_session_evidence(
                 "farm01",
                 agent_id,
                 gateway_node
               )
             )
           end)

    assert {:ok, %{control_session_pid: ^tonka_pid, partition_id: "tonka01"}} =
             AgentCommandBus.resolve_control_session_evidence(
               "tonka01",
               agent_id,
               gateway_node
             )

    assert {:error, {:agent_partition_ambiguous, ^agent_id}} =
             AgentCommandBus.resolve_control_session_evidence(agent_id)
  end

  test "legacy agent-only keys are observable but cannot authorize control evidence" do
    agent_id = "legacy-agent-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Session,
         name:
           ProcessRegistry.via(
             {:agent_control, agent_id, node()},
             control_metadata(agent_id, "default", node())
           )},
        id: {:legacy_session, agent_id}
      )

    assert eventually(fn ->
             Enum.any?(ProcessRegistry.list_agent_controls(agent_id), fn
               {^pid, _metadata} -> true
               _entry -> false
             end)
           end)

    assert [] == ProcessRegistry.lookup_agent_control("default", agent_id)

    assert {:error, {:agent_offline, ^agent_id}} =
             AgentCommandBus.resolve_control_session_evidence(agent_id)
  end

  defp start_session(agent_id, partition_id, gateway_node, marker) do
    start_supervised!(
      {Session,
       name:
         ProcessRegistry.via(
           {:agent_control, partition_id, agent_id, gateway_node},
           control_metadata(agent_id, partition_id, gateway_node)
         )},
      id: {:control_session, marker, agent_id}
    )
  end

  defp control_metadata(agent_id, partition_id, gateway_node) do
    %{
      agent_id: agent_id,
      partition_id: partition_id,
      gateway_node: gateway_node,
      capabilities: ["test"]
    }
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
