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

  test "online enumeration preserves canonical mapper session evidence" do
    agent_id = "mapper-agent-#{System.unique_integer([:positive])}"
    gateway_node = :gateway@mapper
    pid = start_session(agent_id, "default", gateway_node, :mapper, ["mapper", "icmp"])

    assert eventually(fn ->
             Enum.any?(AgentCommandBus.list_online_agents(), fn session ->
               session.agent_id == agent_id and session.partition_id == "default" and
                 session.pid == pid and session.capabilities == ["mapper", "icmp"] and
                 session.canonical_principal?
             end)
           end)
  end

  test "all-agents listing returns every online sweep agent in the partition" do
    alma = "agent-alma-#{System.unique_integer([:positive])}"
    k8s = "k8s-agent-#{System.unique_integer([:positive])}"
    other = "other-partition-#{System.unique_integer([:positive])}"
    gateway_node = :gateway@sweep

    start_session(alma, "default", gateway_node, :alma, ["sweep", "icmp"])
    start_session(k8s, "default", gateway_node, :k8s, ["sweep", "icmp"])
    start_session(other, "rids", gateway_node, :rids, ["sweep", "icmp"])

    assert eventually(fn ->
             ids =
               "default"
               |> AgentCommandBus.list_online_agents_for_assignment("sweep")
               |> Enum.map(& &1.agent_id)
               |> Enum.sort()

             ids == Enum.sort([alma, k8s])
           end)
  end

  test "unassigned selection uses remote registry entries when no local registry is present" do
    agent_id = "remote-mapper-#{System.unique_integer([:positive])}"
    gateway_node = :serviceradar_agent_gateway@remote

    metadata = %{
      agent_id: agent_id,
      partition_id: "default",
      gateway_node: gateway_node,
      capabilities: ["mapper"]
    }

    entry =
      {{:agent_control, "default", agent_id, gateway_node}, self(), metadata}

    test_pid = self()

    remote_reader = fn function, args ->
      send(test_pid, {:registry_rpc, function, args})
      [entry, entry]
    end

    assert {:ok, ^agent_id, pid, ^metadata} =
             AgentCommandBus.pick_online_agent("default", "mapper",
               registry_present?: false,
               local_registry_reader: fn _type -> flunk("local registry should not be read") end,
               registry_rpc: remote_reader
             )

    assert pid == self()
    assert_received {:registry_rpc, :select_by_type, [:agent_control]}
  end

  test "registry node discovery includes every core and gateway but excludes web nodes" do
    nodes = [
      :serviceradar_web_ng@web,
      :serviceradar_core@core_b,
      :serviceradar_agent_gateway@gateway_a,
      :serviceradar_core@core_a,
      :unrelated@other
    ]

    assert ProcessRegistry.registry_nodes(nodes) == [
             :serviceradar_agent_gateway@gateway_a,
             :serviceradar_core@core_a,
             :serviceradar_core@core_b
           ]
  end

  defp start_session(agent_id, partition_id, gateway_node, marker, capabilities \\ ["test"]) do
    start_supervised!(
      {Session,
       name:
         ProcessRegistry.via(
           {:agent_control, partition_id, agent_id, gateway_node},
           control_metadata(agent_id, partition_id, gateway_node, capabilities)
         )},
      id: {:control_session, marker, agent_id}
    )
  end

  defp control_metadata(agent_id, partition_id, gateway_node, capabilities \\ ["test"]) do
    %{
      agent_id: agent_id,
      partition_id: partition_id,
      gateway_node: gateway_node,
      capabilities: capabilities
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
