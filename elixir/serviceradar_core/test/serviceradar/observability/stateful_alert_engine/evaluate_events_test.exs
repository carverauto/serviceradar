defmodule ServiceRadar.Observability.StatefulAlertEngine.EvaluateEventsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.StatefulAlertEngine

  # Engine-authored events must not recurse into durable admission.
  test "the engine's own events are answered without recursively admitting work" do
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
