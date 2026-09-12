defmodule ServiceRadar.Events.HealthWriterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Events.HealthWriter
  alias ServiceRadar.Infrastructure.HealthEvent

  defp health_event(overrides) do
    struct(
      HealthEvent,
      Map.merge(
        %{
          entity_type: :core,
          entity_id: "seasonal-baseline-freshness",
          old_state: :healthy,
          new_state: :unhealthy,
          reason: :health_check_failed,
          node: "serviceradar_core@node-a",
          metadata: %{"freshness_hours" => 26},
          recorded_at: ~U[2026-09-12 10:00:00Z]
        },
        overrides
      )
    )
  end

  # The stored internal log used to carry only ingest metadata as attributes,
  # so no event rule could match a core check going unhealthy and no incident
  # could be grouped per check. The `health` block is what the seeded
  # promotion and stateful rules key on.
  test "payload carries a structured health block for rule matching and grouping" do
    payload = HealthWriter.payload(health_event(%{}))

    assert payload.log_name == "health.state_change"
    assert payload.severity_id == 4

    assert payload.attributes == %{
             "health" => %{
               "entity_type" => "core",
               "entity_id" => "seasonal-baseline-freshness",
               "old_state" => "healthy",
               "new_state" => "unhealthy",
               "reason" => "health_check_failed"
             }
           }

    assert payload.message =~ "seasonal-baseline-freshness"
  end

  test "a recovery is informational and says so in the health block" do
    payload = HealthWriter.payload(health_event(%{old_state: :unhealthy, new_state: :healthy}))

    assert payload.severity_id == 1
    assert payload.attributes["health"]["new_state"] == "healthy"
    assert payload.attributes["health"]["old_state"] == "unhealthy"
  end

  test "missing reason and node do not break the health block" do
    payload = HealthWriter.payload(health_event(%{reason: nil, node: nil}))

    assert payload.attributes["health"]["reason"] == nil
    assert payload.attributes["health"]["entity_id"] == "seasonal-baseline-freshness"
  end
end
