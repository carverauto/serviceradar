defmodule ServiceRadar.ClusterHealthEdgePipelineTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ClusterHealth

  @evaluated_at ~U[2026-11-09 12:00:00Z]

  defp snapshot(overrides \\ %{}), do: [{:core@a, {:ok, {:ok, stats(overrides)}}}]

  defp stats(overrides) do
    Map.merge(
      %{
        node: "core@a",
        contracts: [
          %{contract: "serviceradar.metrics.batch/1", gateway_withheld: 3, gateway_admitted: 10},
          %{contract: "serviceradar.sysmon/1", gateway_withheld: 0, gateway_admitted: 5}
        ],
        dead_letter_reasons: [
          %{contract: "serviceradar.metrics.batch/1", reason: "awaiting_roll_forward", count: 7},
          %{contract: "serviceradar.metrics.batch/1", reason: "poison_record", count: 1}
        ],
        consumers: []
      },
      overrides
    )
  end

  defp epochs do
    {:ok,
     [
       %{epoch: 1_000_001, state: :draining},
       %{epoch: 1_000_002, state: :active},
       %{epoch: 1_000_003, state: :candidate}
     ]}
  end

  test "a waiting candidate names the epoch and each component not holding it" do
    transition = %{
      outcome: {:waiting, 1_000_003, [{:gateway, "gw-1", :no_report}, :no_core_node]},
      evaluated_at: @evaluated_at
    }

    section = ClusterHealth.edge_pipeline_status(snapshot(), transition, epochs(), {:ok, %{}})

    assert section.issuer_key_present == true

    assert section.epochs == %{
             active: 1_000_002,
             candidate: 1_000_003,
             draining: [1_000_001],
             error: nil
           }

    assert section.transition.outcome == "waiting"
    assert section.transition.epoch == 1_000_003
    assert section.transition.evaluated_at == @evaluated_at

    assert section.transition.waiting_on == [
             "gateway gw-1 has not reported its registry",
             "no live core node reported its catalog"
           ]

    roll_forward = section.awaiting_roll_forward

    assert roll_forward.withheld_by_contract == [
             %{contract: "serviceradar.metrics.batch/1", count: 3}
           ]

    assert roll_forward.dead_lettered_by_contract == [
             %{
               contract: "serviceradar.metrics.batch/1",
               reason: "awaiting_roll_forward",
               count: 7
             }
           ]

    assert roll_forward.overflow == nil
    assert roll_forward.nodes == ["core@a"]
    assert roll_forward.error == nil
  end

  test "awaiting-roll-forward counts sum every node: gateways withhold, cores dead-letter" do
    gateway =
      stats(%{
        node: "gateway@a",
        contracts: [%{contract: "serviceradar.metrics.batch/1", gateway_withheld: 4}],
        dead_letter_reasons: []
      })

    core_a = stats(%{node: "core@a", contracts: []})

    core_b =
      stats(%{
        node: "core@b",
        contracts: [],
        dead_letter_reasons: [
          %{contract: "serviceradar.metrics.batch/1", reason: "awaiting_roll_forward", count: 2}
        ]
      })

    results = [
      {:core@a, {:ok, {:ok, core_a}}},
      {:core@b, {:ok, {:ok, core_b}}},
      {:gateway@a, {:ok, {:ok, gateway}}},
      {:web@a, {:ok, {:error, :unavailable}}}
    ]

    roll_forward =
      ClusterHealth.edge_pipeline_status(results, nil, epochs(), {:ok, %{}}).awaiting_roll_forward

    assert roll_forward.withheld_by_contract == [
             %{contract: "serviceradar.metrics.batch/1", count: 4}
           ]

    assert roll_forward.dead_lettered_by_contract == [
             %{contract: "serviceradar.metrics.batch/1", reason: "awaiting_roll_forward", count: 9}
           ]

    assert roll_forward.nodes == ["core@a", "core@b", "gateway@a"]
    assert roll_forward.error == nil
  end

  test "a node that does not answer leaves an explicit error, not a silent zero" do
    results = snapshot() ++ [{:gateway@a, {:error, {:erpc, :noconnection}}}]

    roll_forward =
      ClusterHealth.edge_pipeline_status(results, nil, epochs(), {:ok, %{}}).awaiting_roll_forward

    assert roll_forward.error =~ "gateway@a"
    assert roll_forward.overflow == nil
  end

  test "no candidate, no key and no snapshot degrade to explicit unknowns" do
    transition = %{outcome: :no_candidate, evaluated_at: @evaluated_at}

    section =
      ClusterHealth.edge_pipeline_status(
        [{:core@a, {:ok, {:error, :unavailable}}}],
        transition,
        {:ok, []},
        {:error, :no_key}
      )

    assert section.issuer_key_present == false
    assert section.epochs == %{active: nil, candidate: nil, draining: [], error: nil}

    assert section.transition == %{
             outcome: "no_candidate",
             evaluated_at: @evaluated_at,
             epoch: nil,
             waiting_on: []
           }

    assert section.awaiting_roll_forward == %{
             withheld_by_contract: [],
             dead_lettered_by_contract: [],
             overflow: nil,
             nodes: [],
             error: "no node reported pipeline stats"
           }
  end

  test "activation, abandonment and errors map to their outcomes" do
    activated = %{outcome: {:activated, 1_000_002, 1_000_001}, evaluated_at: @evaluated_at}
    abandoned = %{outcome: {:abandoned, 1_000_003}, evaluated_at: @evaluated_at}
    failed = %{outcome: {:error, :no_key}, evaluated_at: @evaluated_at}

    assert %{outcome: "activated", epoch: 1_000_002} =
             ClusterHealth.edge_pipeline_status(snapshot(), activated, epochs(), {:ok, %{}}).transition

    assert %{outcome: "abandoned", epoch: 1_000_003} =
             ClusterHealth.edge_pipeline_status(snapshot(), abandoned, epochs(), {:ok, %{}}).transition

    assert %{outcome: "error", waiting_on: []} =
             ClusterHealth.edge_pipeline_status(snapshot(), failed, epochs(), {:ok, %{}}).transition

    assert %{outcome: "unknown", epoch: nil} =
             ClusterHealth.edge_pipeline_status(snapshot(), nil, epochs(), {:ok, %{}}).transition
  end

  test "an unreadable epoch table leaves an explicit error, not silent nils" do
    section =
      ClusterHealth.edge_pipeline_status(snapshot(), nil, {:error, :econnrefused}, {:ok, %{}})

    assert section.epochs.active == nil
    assert section.epochs.error =~ "econnrefused"
  end
end
