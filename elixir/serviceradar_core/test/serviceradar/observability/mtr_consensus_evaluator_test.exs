defmodule ServiceRadar.Observability.MtrConsensusEvaluatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrConsensusEvaluator

  test "mixed unreachable and success classifies as path_scoped_issue" do
    outcomes = [
      %{agent_id: "a1", target_reached: false},
      %{agent_id: "a2", target_reached: true},
      %{agent_id: "a3", target_reached: true}
    ]

    result = MtrConsensusEvaluator.classify(outcomes, %{"consensus_min_agents" => 2})
    assert result.classification == :path_scoped_issue
  end

  test "majority unreachable classifies as target_outage" do
    outcomes = [
      %{agent_id: "a1", target_reached: false},
      %{agent_id: "a2", target_reached: false},
      %{agent_id: "a3", target_reached: true}
    ]

    result =
      MtrConsensusEvaluator.classify(outcomes, %{
        consensus_mode: "majority",
        consensus_min_agents: 2
      })

    assert result.classification == :target_outage
  end

  test "threshold mode requires configured probability" do
    outcomes = [
      %{agent_id: "a1", target_reached: false},
      %{agent_id: "a2", target_reached: false},
      %{agent_id: "a3", target_reached: true},
      %{agent_id: "a4", target_reached: true}
    ]

    result =
      MtrConsensusEvaluator.classify(outcomes, %{
        consensus_mode: "threshold",
        consensus_threshold: 0.75,
        consensus_min_agents: 2
      })

    assert result.classification != :target_outage
  end

  test "anomalous reaches classify as degraded_path" do
    outcomes = [
      %{agent_id: "a1", target_reached: true, packet_loss_pct: 35.0},
      %{agent_id: "a2", target_reached: true, avg_rtt_ms: 300.0},
      %{agent_id: "a3", target_reached: true}
    ]

    result = MtrConsensusEvaluator.classify(outcomes, %{})
    assert result.classification == :degraded_path
  end

  test "all successful outcomes classify as healthy" do
    outcomes = [
      %{agent_id: "a1", target_reached: true},
      %{agent_id: "a2", target_reached: true},
      %{agent_id: "a3", target_reached: true}
    ]

    result =
      MtrConsensusEvaluator.classify(outcomes, %{
        consensus_mode: "majority",
        consensus_min_agents: 2
      })

    assert result.classification == :healthy
    assert result.confidence > 0.0
  end

  test "min agent gate yields insufficient evidence" do
    outcomes = [%{agent_id: "a1", target_reached: false}]

    result = MtrConsensusEvaluator.classify(outcomes, %{consensus_min_agents: 2})
    assert result.classification == :insufficient_evidence
  end

  test "aggregate_weighted_votes respects weights" do
    outcomes = [
      %{agent_id: "a1", target_reached: false, weight: 2.0},
      %{agent_id: "a2", target_reached: true, weight: 1.0}
    ]

    votes = MtrConsensusEvaluator.aggregate_weighted_votes(outcomes, %{})
    assert_in_delta votes.p_unreachable, 0.666, 0.01
    assert_in_delta votes.p_success, 0.333, 0.01
    assert votes.counts.unreachable == 1
    assert votes.counts.success == 1
  end
end
