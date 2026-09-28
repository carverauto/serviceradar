defmodule ServiceRadar.Events.HealthStateChangePipelineTest do
  # A core health transition travels the whole internal path: HealthWriter
  # publishes an internal log, EventWriter stores and promotes it to a
  # `health.core.state_change` event, and the seeded
  # `core_health_check_unhealthy` rule opens one alert for it. The test
  # environment's publisher hands each publish to the EventWriter processor for
  # its subject, as the JetStream consumer would.
  use ServiceRadar.DataCase, async: false

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
    assert promoted_event_count(entity_id) == 1
    assert open_alert_count(entity_id) == 1

    # A second report of the same outage is promoted and evaluated too, but the
    # incident it belongs to is already open.
    assert :ok = HealthWriter.write(transition(entity_id, :healthy, :unhealthy))
    assert promoted_event_count(entity_id) == 2
    assert open_alert_count(entity_id) == 1
  end

  test "a transition of a non-core entity is not promoted" do
    entity_id = "pipeline-gateway-#{System.unique_integer([:positive])}"

    event = %{transition(entity_id, :healthy, :unhealthy) | entity_type: :gateway}

    assert :ok = HealthWriter.write(event)
    assert promoted_event_count(entity_id) == 0
    assert open_alert_count(entity_id) == 0
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
