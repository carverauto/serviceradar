defmodule ServiceRadar.Observability.StatefulAlertEngine.EvaluateEventsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.StatefulAlertEngine

  # No engine shard runs here. Every shard skips the engine's own events, so a
  # batch of nothing else is answered without reaching one.
  test "the engine's own events are answered without reaching a shard" do
    events = [
      %{
        id: "00000000-0000-4000-8000-0000000000e1",
        log_name: "alert.health.core_check",
        metadata: %{"serviceradar" => %{"stateful_rule" => true}}
      },
      %{
        id: "00000000-0000-4000-8000-0000000000e2",
        log_name: "alert.rule.threshold",
        log_provider: "serviceradar.core",
        metadata: %{}
      }
    ]

    assert :ok = StatefulAlertEngine.evaluate_events(events)
  end
end
