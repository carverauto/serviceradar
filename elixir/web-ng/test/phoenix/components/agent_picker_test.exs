defmodule ServiceRadarWebNGWeb.Components.AgentPickerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Components.AgentPicker

  @moduletag :db_free

  defp sample_agents do
    [
      %{uid: "agent-edge-01", host: "edge-01.example.test", ip: "198.51.100.11"},
      %{uid: "agent-hub-01", host: "hub-01.example.test", ip: "198.51.100.21"},
      %{uid: "agent-branch-02", host: "branch-02.example.test", ip: "203.0.113.42"}
    ]
  end

  describe "filter_agents/4" do
    test "filters case-insensitively by uid, host, and ip" do
      agents = sample_agents()
      netperf_ids = MapSet.new(["agent-edge-01", "agent-hub-01"])

      assert Enum.map(AgentPicker.filter_agents(agents, "", false, netperf_ids), & &1.uid) == [
               "agent-edge-01",
               "agent-hub-01",
               "agent-branch-02"
             ]

      assert Enum.map(AgentPicker.filter_agents(agents, "HUB", false, netperf_ids), & &1.uid) == [
               "agent-hub-01"
             ]

      assert Enum.map(AgentPicker.filter_agents(agents, "203.0.113", false, netperf_ids), & &1.uid) == [
               "agent-branch-02"
             ]

      assert Enum.map(AgentPicker.filter_agents(agents, "branch-02.example", false, netperf_ids), & &1.uid) == [
               "agent-branch-02"
             ]
    end

    test "respects only_netperf? filter" do
      agents = sample_agents()
      netperf_ids = MapSet.new(["agent-hub-01"])

      assert Enum.map(AgentPicker.filter_agents(agents, "", true, netperf_ids), & &1.uid) == [
               "agent-hub-01"
             ]
    end
  end

  describe "agent_picker_field/1" do
    test "renders single-select trigger with badges and hidden input" do
      agents_by_uid = Map.new(sample_agents(), &{&1.uid, &1})

      html =
        render_component(&AgentPicker.agent_picker_field/1,
          id: "test-single-picker",
          label: "Sender Agent",
          field_name: "run[sender_agent_id]",
          mode: :single,
          selected: "agent-edge-01",
          target_key: "run_sender",
          agents_by_uid: agents_by_uid,
          online_agent_ids: MapSet.new(["agent-edge-01"]),
          netperf_agent_ids: MapSet.new(["agent-edge-01"])
        )

      assert html =~ ~s(name="run[sender_agent_id]")
      assert html =~ ~s(value="agent-edge-01")
      assert html =~ "198.51.100.11"
      assert html =~ "Online"
      assert html =~ "netperf"
    end

    test "renders multi-select chips and comma-joined hidden input" do
      html =
        render_component(&AgentPicker.agent_picker_field/1,
          id: "test-multi-picker",
          label: "Spoke Agents",
          field_name: "policy[spoke_agent_uids_text]",
          mode: :multi,
          selected: "agent-edge-01, agent-branch-02",
          target_key: "policy_spokes"
        )

      assert html =~ ~s(name="policy[spoke_agent_uids_text]")
      assert html =~ ~s(value="agent-edge-01, agent-branch-02")
      assert html =~ "Remove agent-edge-01"
      assert html =~ "Remove agent-branch-02"
      assert html =~ "Add or change agents (2)"
    end
  end

  describe "agent_picker_modal/1" do
    test "renders matching agents with max_visible cap and selection state" do
      html =
        render_component(&AgentPicker.agent_picker_modal/1,
          id: "test-picker-modal",
          open: true,
          title: "Select Spoke Agents",
          mode: :multi,
          agents: sample_agents(),
          selected: ["agent-hub-01"],
          query: "",
          only_netperf: false,
          max_visible: 2,
          online_agent_ids: MapSet.new(["agent-hub-01"]),
          netperf_agent_ids: MapSet.new(["agent-hub-01"])
        )

      assert html =~ "Select Spoke Agents"
      assert html =~ "Showing 2 of 3 matching agents"
      assert html =~ "1 selected"
      assert html =~ "agent-edge-01"
      assert html =~ "agent-hub-01"
      refute html =~ "agent-branch-02"
      assert html =~ "Selected"
    end
  end
end
