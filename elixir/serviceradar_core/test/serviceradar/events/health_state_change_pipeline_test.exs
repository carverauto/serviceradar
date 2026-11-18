defmodule ServiceRadar.Events.HealthStateChangePipelineTest do
  # A core health transition travels the whole internal path: HealthWriter
  # publishes an internal log, EventWriter stores and promotes it to a
  # `health.core.state_change` event, and the seeded
  # `core_health_check_unhealthy` rule opens one alert for it. The test
  # environment's publisher hands each publish to the EventWriter processor for
  # its subject, as the JetStream consumer would.
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.ClusterHealth
  alias ServiceRadar.Events.HealthWriter
  alias ServiceRadar.Infrastructure.HealthEvent
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.Observability.RuleSeeder
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    :ok = RuleSeeder.seed_all()
    LogPromotion.invalidate_rules_cache()
    reset_engine()
    on_exit(&reset_engine/0)
    :ok
  end

  test "an unhealthy core check is promoted through EventWriter and alerts once" do
    entity_id = "pipeline-check-#{System.unique_integer([:positive])}"

    assert :ok = HealthWriter.write(transition(entity_id, :healthy, :unhealthy))
    TestSupport.complete_alert_effects!()
    assert promoted_event_count(entity_id) == 1
    assert open_alert_count(entity_id) == 1

    # A second report of the same outage is promoted and evaluated too, but the
    # incident it belongs to is already open.
    assert :ok = HealthWriter.write(transition(entity_id, :healthy, :unhealthy))
    TestSupport.complete_alert_effects!()
    assert promoted_event_count(entity_id) == 2
    assert open_alert_count(entity_id) == 1
  end

  test "a disconnected agent alerts once and a reconnect resolves it" do
    agent_id = "pipeline-agent-#{System.unique_integer([:positive])}"

    assert :ok = HealthWriter.write(agent_transition(agent_id, :connected, :disconnected))
    TestSupport.complete_alert_effects!()
    assert agent_alert_statuses(agent_id) == ["pending"]

    # A transition that is neither the outage nor its recovery changes nothing.
    assert :ok = HealthWriter.write(agent_transition(agent_id, :disconnected, :connecting))
    TestSupport.complete_alert_effects!()
    assert agent_alert_statuses(agent_id) == ["pending"]

    assert :ok = HealthWriter.write(agent_transition(agent_id, :disconnected, :connected))
    TestSupport.complete_alert_effects!()
    assert agent_alert_statuses(agent_id) == ["resolved"]
  end

  test "disconnected agents are separate incidents" do
    first = "pipeline-agent-a-#{System.unique_integer([:positive])}"
    second = "pipeline-agent-b-#{System.unique_integer([:positive])}"

    assert :ok = HealthWriter.write(agent_transition(first, :connected, :disconnected))
    assert :ok = HealthWriter.write(agent_transition(second, :degraded, :disconnected))
    TestSupport.complete_alert_effects!()

    assert agent_alert_statuses(first) == ["pending"]
    assert agent_alert_statuses(second) == ["pending"]

    # One agent being retired clears its own incident and leaves the other open.
    assert :ok = HealthWriter.write(agent_transition(first, :disconnected, :unavailable))
    TestSupport.complete_alert_effects!()

    assert agent_alert_statuses(first) == ["resolved"]
    assert agent_alert_statuses(second) == ["pending"]
  end

  test "a transition of a non-core entity is not promoted" do
    entity_id = "pipeline-gateway-#{System.unique_integer([:positive])}"

    event = %{transition(entity_id, :healthy, :unhealthy) | entity_type: :gateway}

    assert :ok = HealthWriter.write(event)
    assert promoted_event_count(entity_id) == 0
    assert open_alert_count(entity_id) == 0
  end

  test "unhealthy edge spools and held dead letters open default core health alerts" do
    edge_pipeline = %{
      spools: %{
        unhealthy_agents: [
          %{agent_id: "agent-1", reason: "spool_stuck", detail: %{}}
        ],
        error: nil
      },
      dead_letters: %{
        held_messages: 2,
        by_reason: [
          %{contract: "serviceradar.metrics.batch/1", reason: "decode_failed", count: 2}
        ],
        error: nil
      }
    }

    assert :ok = ClusterHealth.record_edge_pipeline_health(edge_pipeline)
    TestSupport.complete_alert_effects!()

    assert promoted_event_count(ClusterHealth.spool_health_check()) >= 1
    assert open_alert_count(ClusterHealth.spool_health_check()) == 1

    assert promoted_event_count(ClusterHealth.dead_letter_health_check()) >= 1
    assert open_alert_count(ClusterHealth.dead_letter_health_check()) == 1
  end

  defp transition(entity_id, old_state, new_state) do
    %HealthEvent{
      entity_type: :core,
      entity_id: entity_id,
      old_state: old_state,
      new_state: new_state,
      reason: "pipeline test",
      node: "core@host01.example.com",
      metadata: %{},
      recorded_at: DateTime.utc_now()
    }
  end

  defp agent_transition(agent_id, old_state, new_state) do
    %{transition(agent_id, old_state, new_state) | entity_type: :agent}
  end

  defp agent_alert_statuses(agent_id) do
    List.flatten(
      Repo.query!(
        """
        SELECT status
        FROM platform.alerts
        WHERE metadata->>'incident_rule_name' = 'agent_disconnected'
          AND metadata #>> '{incident_group_values,health.entity_id}' = $1
        ORDER BY created_at
        """,
        [agent_id]
      ).rows
    )
  end

  defp promoted_event_count(entity_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*)
        FROM platform.ocsf_events
        WHERE log_name = 'health.core.state_change'
          AND unmapped #>> '{log_attributes,health,entity_id}' = $1
        """,
        [entity_id]
      )

    count
  end

  defp open_alert_count(entity_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*)
        FROM platform.alerts
        WHERE metadata->>'incident_rule_name' = 'core_health_check_unhealthy'
          AND metadata #>> '{incident_group_values,health.entity_id}' = $1
        """,
        [entity_id]
      )

    count
  end

  defp reset_engine do
    case ProcessRegistry.lookup(:stateful_alert_engine) do
      [{pid, _}] ->
        _ = ProcessRegistry.terminate_child(pid)
        Process.sleep(25)
        :ok

      _ ->
        :ok
    end
  end
end
