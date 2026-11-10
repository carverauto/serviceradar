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

  defp epochs(invalid \\ []) do
    {:ok,
     %{
       epochs: [
         %{epoch: 1_000_001, state: :draining},
         %{epoch: 1_000_002, state: :active},
         %{epoch: 1_000_003, state: :candidate}
       ],
       invalid: invalid
     }}
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
             %{
               contract: "serviceradar.metrics.batch/1",
               reason: "awaiting_roll_forward",
               count: 9
             }
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
        {:ok, %{epochs: [], invalid: []}},
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

  test "a refused epoch row is named in the error and never listed as active" do
    view =
      {:ok,
       %{
         epochs: [%{epoch: 1_000_001, state: :draining}],
         invalid: [%{epoch: 1_000_002, state: :active, reason: :registry_epoch_signature_invalid}]
       }}

    epochs = ClusterHealth.edge_pipeline_status(snapshot(), nil, view, {:ok, %{}}).epochs

    assert epochs.active == nil
    assert epochs.draining == [1_000_001]
    assert epochs.error =~ "1000002"
    assert epochs.error =~ "registry_epoch_signature_invalid"
  end

  test "stuck or full agent spools and held dead letters record unhealthy core checks and clear on recovery" do
    stuck_spool = %{
      available: true,
      health_available: true,
      wedged: false,
      admission_paused: false,
      unresolved_count: 5,
      oldest_unresolved_age_known: true,
      oldest_unresolved_age_seconds: 901,
      unresolved_bytes: 4096,
      bytes_used: 4096,
      budget_bytes: 1_073_741_824
    }

    full_spool = %{
      available: true,
      health_available: true,
      wedged: false,
      admission_paused: true,
      unresolved_count: 100,
      oldest_unresolved_age_known: true,
      oldest_unresolved_age_seconds: 120,
      unresolved_bytes: 858_993_460,
      bytes_used: 858_993_460,
      budget_bytes: 1_073_741_824
    }

    dlq_consumer = %{
      subject_class: "edge_record_dlq",
      stream: "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK",
      durable: "serviceradar-event-writer-edge-record-dlq",
      pending: 0,
      ack_pending: 0,
      redelivered: 0,
      stream_messages: 3,
      sampled_at_ms: 1_000
    }

    runtime_agents =
      {:ok,
       %{
         "agent-1" => %{active: true, edge_record_spool: stuck_spool},
         "agent-2" => %{active: true, edge_record_spool: full_spool},
         "agent-offline" => %{active: false, edge_record_spool: stuck_spool}
       }}

    section =
      ClusterHealth.edge_pipeline_status(
        snapshot(%{consumers: [dlq_consumer]}),
        nil,
        epochs(),
        {:ok, %{}},
        runtime_agents
      )

    assert section.dead_letters.held_messages == 3
    assert section.dead_letters.error == nil

    assert Enum.map(section.spools.unhealthy_agents, &{&1.agent_id, &1.reason}) == [
             {"agent-1", "spool_stuck"},
             {"agent-2", "spool_backpressure"}
           ]

    recorded =
      record_checks(section)

    assert recorded[ClusterHealth.spool_health_check()] ==
             {false,
              %{
                "unhealthy_agents" => [
                  %{"agent_id" => "agent-1", "reason" => "spool_stuck"},
                  %{"agent_id" => "agent-2", "reason" => "spool_backpressure"}
                ]
              }}

    assert {false, %{"held_messages" => 3, "by_reason" => [_ | _]}} =
             recorded[ClusterHealth.dead_letter_health_check()]

    # Replaying/purging the DLQ brings stream_messages to 0 even though cumulative
    # dead_letter_reasons stay non-zero, and draining the spools clears the spool check.
    healthy_spool = %{
      stuck_spool
      | unresolved_count: 0,
        oldest_unresolved_age_seconds: 0,
        unresolved_bytes: 0,
        bytes_used: 0
    }

    cleared_section =
      ClusterHealth.edge_pipeline_status(
        snapshot(%{consumers: [%{dlq_consumer | stream_messages: 0, sampled_at_ms: 2_000}]}),
        nil,
        epochs(),
        {:ok, %{}},
        {:ok, %{"agent-1" => %{active: true, edge_record_spool: healthy_spool}}}
      )

    cleared = record_checks(cleared_section)

    assert cleared[ClusterHealth.spool_health_check()] == {true, %{"unhealthy_agents" => []}}
    assert {true, %{"held_messages" => 0}} = cleared[ClusterHealth.dead_letter_health_check()]
  end

  test "unknown tracker state or unsampled DLQ depth never clears an open alert" do
    unsampled =
      ClusterHealth.edge_pipeline_status(
        snapshot(%{dead_letter_reasons: [], consumers: []}),
        nil,
        epochs(),
        {:ok, %{}},
        {:error, :agent_tracker_unavailable}
      )

    assert unsampled.spools.error =~ "agent_tracker_unavailable"
    assert unsampled.dead_letters.held_messages == nil
    assert record_checks(unsampled) == %{}
  end

  test "a failed DLQ depth poll after a replay does not reopen the dead-letter check" do
    failed_poll = %{
      subject_class: "edge_record_dlq",
      stream: "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK",
      durable: "serviceradar-event-writer-edge-record-dlq",
      pending: 0,
      ack_pending: 0,
      redelivered: 0,
      stream_messages: nil,
      sampled_at_ms: 3_000
    }

    section =
      ClusterHealth.edge_pipeline_status(
        snapshot(%{consumers: [failed_poll]}),
        nil,
        epochs(),
        {:ok, %{}},
        {:ok, %{}}
      )

    assert section.dead_letters.held_messages == nil
    assert [_ | _] = section.dead_letters.by_reason
    refute Map.has_key?(record_checks(section), ClusterHealth.dead_letter_health_check())
  end

  defp record_checks(section) do
    parent = self()

    ClusterHealth.record_edge_pipeline_health(section, fn check, healthy?, metadata, _opts ->
      send(parent, {:recorded, check, healthy?, metadata})
      :ok
    end)

    collect_recorded(%{})
  end

  defp collect_recorded(acc) do
    receive do
      {:recorded, check, healthy?, metadata} ->
        collect_recorded(Map.put(acc, check, {healthy?, metadata}))
    after
      0 -> acc
    end
  end
end
