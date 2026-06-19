defmodule ServiceRadar.Observability.SeasonalDisposition.VerdictEmitterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.SeasonalDisposition.VerdictEmitter

  @attrs %{
    series_key: "partition:default|device:device-a|metric:cpu.usage_percent",
    resource_type: "cpu",
    resource_id: "device-a",
    resource_label: "host-a",
    metric_class: "cpu",
    metric_name: "cpu.usage_percent",
    disposition: "seasonal_breach",
    status: "breach",
    score: 4.2,
    consecutive_anomalous: 3,
    dow: 5,
    hod: 13,
    sample_value: 88.0,
    evaluated_at: ~U[2026-06-12 13:15:00Z],
    bucket_started_at: ~U[2026-06-12 13:00:00Z],
    bucket_ended_at: ~U[2026-06-12 14:00:00Z],
    metadata: %{"source" => "cpu_seasonal", "verdict_source" => "central-seasonal"}
  }

  test "event id is stable across worker run time for the same seasonal condition" do
    later_run =
      @attrs
      |> Map.put(:evaluated_at, ~U[2026-06-12 15:15:00Z])
      |> Map.put(:bucket_started_at, ~U[2026-06-12 15:00:00Z])
      |> Map.put(:bucket_ended_at, ~U[2026-06-12 16:00:00Z])

    assert VerdictEmitter.event_id(later_run) == VerdictEmitter.event_id(@attrs)

    cleared = Map.put(@attrs, :status, "cleared")
    refute VerdictEmitter.event_id(cleared) == VerdictEmitter.event_id(@attrs)
  end

  test "payload preserves seasonal event timestamp separately from identity" do
    payload = VerdictEmitter.payload(@attrs)

    assert payload["event_id"] == VerdictEmitter.event_id(@attrs)
    assert payload["timestamp"] == "2026-06-12T14:00:00Z"
    assert payload["seasonal_disposition"]["bucket_ended_at"] == "2026-06-12T14:00:00Z"
    assert payload["finding_info"]["source"] == "seasonal_disposition"
  end
end
