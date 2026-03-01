defmodule ServiceRadar.Observability.MtrVantageSelectorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrVantageSelector

  test "baseline selects primary by affinity and health" do
    target = %{partition_id: "p1", gateway_id: "gw-a"}

    candidates = [
      %{
        agent_id: "agent-b",
        partition_id: "p1",
        gateway_id: "gw-b",
        status: :connected,
        capabilities: ["mtr"]
      },
      %{
        agent_id: "agent-a",
        partition_id: "p1",
        gateway_id: "gw-a",
        status: :connected,
        capabilities: ["mtr"]
      }
    ]

    assert {:ok, ["agent-a"]} =
             MtrVantageSelector.select_baseline_vantages(target, %{}, candidates)
  end

  test "baseline can include canary vantages" do
    target = %{partition_id: "p1", gateway_id: "gw-a"}

    candidates = [
      %{
        agent_id: "agent-a",
        partition_id: "p1",
        gateway_id: "gw-a",
        status: :connected,
        capabilities: ["mtr"]
      },
      %{
        agent_id: "agent-b",
        partition_id: "p1",
        gateway_id: "gw-b",
        status: :connected,
        capabilities: ["mtr"]
      },
      %{
        agent_id: "agent-c",
        partition_id: "p1",
        gateway_id: "gw-c",
        status: :connected,
        capabilities: ["mtr"]
      }
    ]

    policy = %{baseline_canary_vantages: 1}

    assert {:ok, selected} =
             MtrVantageSelector.select_baseline_vantages(target, policy, candidates)

    assert selected == ["agent-a", "agent-b"]
  end

  test "incident selection is bounded by fanout" do
    target = %{partition_id: "p1"}

    candidates =
      Enum.map(1..5, fn n ->
        %{
          agent_id: "agent-#{n}",
          partition_id: "p1",
          status: :connected,
          capabilities: ["mtr"],
          in_flight: n - 1
        }
      end)

    policy = %{incident_fanout_max_agents: 3}

    assert {:ok, selected} =
             MtrVantageSelector.select_incident_vantages(target, policy, candidates)

    assert length(selected) == 3
  end

  test "selector returns no_candidates when none are eligible" do
    target = %{partition_id: "p1"}

    candidates = [
      %{agent_id: "agent-x", partition_id: "p2", status: :connected, capabilities: ["mtr"]},
      %{agent_id: "agent-y", partition_id: "p1", status: :disconnected, capabilities: ["mtr"]},
      %{agent_id: "agent-z", partition_id: "p1", status: :connected, capabilities: []}
    ]

    assert {:error, :no_candidates} =
             MtrVantageSelector.select_baseline_vantages(target, %{}, candidates)
  end

  test "score sorting is deterministic by agent_id when scores tie" do
    target = %{partition_id: "p1", gateway_id: "gw-a"}

    candidates = [
      %{
        agent_id: "agent-b",
        partition_id: "p1",
        gateway_id: "gw-a",
        status: :connected,
        capabilities: ["mtr"]
      },
      %{
        agent_id: "agent-a",
        partition_id: "p1",
        gateway_id: "gw-a",
        status: :connected,
        capabilities: ["mtr"]
      }
    ]

    [first, second] = MtrVantageSelector.score_candidates(target, %{}, candidates)

    assert first.score == second.score
    assert first.agent_id == "agent-a"
    assert second.agent_id == "agent-b"
  end
end
