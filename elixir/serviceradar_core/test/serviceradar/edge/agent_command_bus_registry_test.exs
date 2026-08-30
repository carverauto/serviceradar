defmodule ServiceRadar.Edge.AgentCommandBusRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.ProcessRegistry

  @moduletag :db_free

  defmodule Session do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, nil, name: opts[:name])

    @impl true
    def init(state), do: {:ok, state}
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:horde)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if !Process.whereis(ProcessRegistry.registry_name()) do
      Enum.each(ProcessRegistry.child_specs(), fn child_spec -> start_supervised!(child_spec) end)
    end

    :ok
  end

  test "selected sweep dispatch uses exactly each canonical agent session partition" do
    first = "selected-a-#{System.unique_integer([:positive])}"
    second = "selected-b-#{System.unique_integer([:positive])}"
    outsider = "outside-selection-#{System.unique_integer([:positive])}"

    start_session(first, "farm01", :gateway@farm, :first, ["sweep"])
    start_session(second, "tonka01", :gateway@tonka, :second, ["sweep"])
    start_session(outsider, "devices", :gateway@devices, :outsider, ["sweep"])

    assert eventually(fn -> canonical_session_visible?(first, "farm01") end)
    assert eventually(fn -> canonical_session_visible?(second, "tonka01") end)

    group = sweep_group([second, first], partition: "devices", agent_id: nil)
    first_command_id = "command-#{first}"
    second_command_id = "command-#{second}"

    assert {:ok,
            %{
              commands: [
                %{agent_id: ^first, command_id: ^first_command_id},
                %{agent_id: ^second, command_id: ^second_command_id}
              ],
              failures: []
            }} =
             AgentCommandBus.run_sweep_group(group, dispatch_fun: recording_dispatch(self()))

    assert_receive {:dispatch, ^first, "sweep.run_group", %{sweep_group_id: "group-1"},
                    first_opts}

    assert first_opts[:required_partition] == "farm01"
    assert first_opts[:required_gateway_node] == :gateway@farm
    assert first_opts[:required_capability] == "sweep"

    assert_receive {:dispatch, ^second, "sweep.run_group", %{sweep_group_id: "group-1"},
                    second_opts}

    assert second_opts[:required_partition] == "tonka01"
    assert second_opts[:required_gateway_node] == :gateway@tonka
    assert second_opts[:required_capability] == "sweep"

    refute_received {:dispatch, ^outsider, _, _, _}
  end

  test "selected sweep dispatch preserves successes and explicit member failures" do
    online = "selected-online-#{System.unique_integer([:positive])}"
    offline = "selected-offline-#{System.unique_integer([:positive])}"
    incapable = "selected-incapable-#{System.unique_integer([:positive])}"

    start_session(online, "scanner-a", :gateway@a, :online, ["sweep"])
    start_session(incapable, "scanner-b", :gateway@b, :incapable, ["icmp"])

    assert eventually(fn -> canonical_session_visible?(online, "scanner-a") end)
    assert eventually(fn -> canonical_session_visible?(incapable, "scanner-b") end)

    group = sweep_group([online, offline, incapable], partition: "devices", agent_id: nil)

    assert {:ok, %{commands: [%{agent_id: ^online}], failures: failures}} =
             AgentCommandBus.run_sweep_group(group, dispatch_fun: recording_dispatch(self()))

    assert Enum.sort_by(failures, & &1.agent_id) ==
             Enum.sort_by(
               [
                 %{agent_id: offline, reason: {:agent_offline, offline}},
                 %{
                   agent_id: incapable,
                   reason: {:agent_capability_missing, incapable, "sweep"}
                 }
               ],
               & &1.agent_id
             )

    assert_receive {:dispatch, ^online, _, _, _}
    refute_received {:dispatch, ^offline, _, _, _}
    refute_received {:dispatch, ^incapable, _, _, _}
  end

  test "selected sweep dispatch fails closed for two canonical partitions before capability filtering" do
    agent_id = "ambiguous-selected-#{System.unique_integer([:positive])}"

    start_session(agent_id, "farm01", :gateway@farm, :ambiguous_farm, ["sweep"])
    start_session(agent_id, "tonka01", :gateway@tonka, :ambiguous_tonka, ["icmp"])

    assert eventually(fn -> canonical_session_visible?(agent_id, "farm01") end)
    assert eventually(fn -> canonical_session_visible?(agent_id, "tonka01") end)

    group = sweep_group([agent_id], partition: "farm01", agent_id: nil)

    assert {:error, {:agent_partition_ambiguous, ^agent_id}} =
             AgentCommandBus.run_sweep_group(group, dispatch_fun: recording_dispatch(self()))

    refute_received {:dispatch, ^agent_id, _, _, _}
  end

  test "selected sweep authority ignores legacy-only sessions and does not make a canonical session ambiguous" do
    canonical = "canonical-selected-#{System.unique_integer([:positive])}"
    legacy_only = "legacy-selected-#{System.unique_integer([:positive])}"

    start_session(canonical, "farm01", :gateway@farm, :canonical, ["sweep"])
    start_legacy_session(canonical, "tonka01", :gateway@legacy, :legacy_shadow, ["sweep"])
    start_legacy_session(legacy_only, "devices", :gateway@legacy, :legacy_only, ["sweep"])

    assert eventually(fn -> canonical_session_visible?(canonical, "farm01") end)

    group = sweep_group([canonical, legacy_only], partition: "devices", agent_id: nil)

    assert {:ok,
            %{
              commands: [%{agent_id: ^canonical}],
              failures: [%{agent_id: ^legacy_only, reason: {:agent_offline, ^legacy_only}}]
            }} =
             AgentCommandBus.run_sweep_group(group, dispatch_fun: recording_dispatch(self()))

    assert_receive {:dispatch, ^canonical, _, _, opts}
    assert opts[:required_partition] == "farm01"
    refute_received {:dispatch, ^legacy_only, _, _, _}
  end

  test "all selected failures publish a zero-success envelope before returning an error" do
    offline = "all-failed-#{System.unique_integer([:positive])}"
    :ok = AgentCommandPubSub.subscribe()

    group = sweep_group([offline], partition: "devices", agent_id: nil)

    assert {:error, {:agent_offline, ^offline}} =
             AgentCommandBus.run_sweep_group(group, dispatch_fun: recording_dispatch(self()))

    assert_receive {:sweep_dispatch,
                    %{
                      sweep_group_id: "group-1",
                      commands: [],
                      failures: [%{agent_id: ^offline, reason: {:agent_offline, ^offline}}],
                      error: {:agent_offline, ^offline}
                    }}
  end

  test "all-agents sweep enumeration stays partition-scoped and returns structured commands" do
    first = "all-a-#{System.unique_integer([:positive])}"
    second = "all-b-#{System.unique_integer([:positive])}"
    wrong_partition = "all-other-#{System.unique_integer([:positive])}"
    wrong_capability = "all-incapable-#{System.unique_integer([:positive])}"

    start_session(first, "devices", :gateway@devices, :all_first, ["sweep"])
    start_session(second, "devices", :gateway@devices, :all_second, ["sweep"])
    start_session(wrong_partition, "other", :gateway@other, :all_other, ["sweep"])
    start_session(wrong_capability, "devices", :gateway@devices, :all_incapable, ["icmp"])

    group = sweep_group([], partition: "devices", agent_id: "stale-scalar-must-be-ignored")

    assert {:ok, %{commands: commands, failures: []}} =
             AgentCommandBus.run_sweep_group(group, dispatch_fun: recording_dispatch(self()))

    assert Enum.map(commands, & &1.agent_id) == Enum.sort([first, second])
    assert_receive {:dispatch, ^first, _, _, _}
    assert_receive {:dispatch, ^second, _, _, _}
    refute_received {:dispatch, ^wrong_partition, _, _, _}
    refute_received {:dispatch, ^wrong_capability, _, _, _}
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

  defp start_legacy_session(agent_id, partition_id, gateway_node, marker, capabilities) do
    start_supervised!(
      {Session,
       name:
         ProcessRegistry.via(
           {:agent_control, agent_id, gateway_node},
           control_metadata(agent_id, partition_id, gateway_node, capabilities)
         )},
      id: {:legacy_control_session, marker, agent_id}
    )
  end

  defp sweep_group(agent_ids, opts) do
    %{
      id: "group-1",
      partition: Keyword.fetch!(opts, :partition),
      agent_ids: agent_ids,
      agent_id: Keyword.get(opts, :agent_id)
    }
  end

  defp recording_dispatch(test_pid) do
    fn agent_id, command_type, payload, opts ->
      send(test_pid, {:dispatch, agent_id, command_type, payload, opts})
      {:ok, "command-#{agent_id}"}
    end
  end

  defp canonical_session_visible?(agent_id, partition_id) do
    AgentCommandBus.lookup_control_session_entries(partition_id, agent_id) != []
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
