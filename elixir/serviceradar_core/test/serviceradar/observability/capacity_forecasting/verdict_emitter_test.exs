defmodule ServiceRadar.Observability.CapacityForecasting.VerdictEmitterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.Observability.CapacityForecasting.VerdictEmitter

  @moduletag :requires_app

  defmodule ExistingTimeRepo do
    def query(_sql, [ids]) do
      # Mirror the real DB: production binds 16-byte UUID binaries and `SELECT id::text`,
      # so canonicalize each bound binary to its string identity (the key the test stores
      # the persisted time under).
      rows =
        Enum.map(ids, fn id ->
          text_id = Ecto.UUID.load!(id)
          [text_id, Process.get({:capacity_existing_ocsf_time, text_id})]
        end)

      {:ok, %{rows: rows}}
    end
  end

  @forecast %{
    forecasted_at: ~U[2026-06-12 12:00:00Z],
    resource_key: "cpu_usage:device-a:host-a",
    resource_type: "cpu",
    resource_id: "device-a",
    resource_label: "host-a / device-a",
    metric_class: "cpu",
    metric_name: "usage_percent",
    horizon_seconds: 86_400,
    horizon_ends_at: ~U[2026-06-13 12:00:00Z],
    window_started_at: ~U[2026-06-01 00:00:00Z],
    window_ended_at: ~U[2026-06-02 23:00:00Z],
    sample_count: 48,
    model: "linear",
    status: "projected",
    current_value: 86.0,
    slope_per_second: 0.0002,
    projected_value: 103.0,
    projected_exhaustion_at: ~U[2026-06-12 22:00:00Z],
    exhaustion_threshold: 100.0,
    confidence: 0.82,
    lower_bound: 97.0,
    upper_bound: 109.0,
    metadata: %{"source" => "cpu_usage"}
  }

  test "publishes a deterministic capacity forecast causal signal" do
    publisher = fn subject, payload, _opts ->
      send(self(), {:published_capacity_verdict, subject, payload})
      :ok
    end

    assert :ok = VerdictEmitter.emit(@forecast, publisher: publisher)

    assert_received {:published_capacity_verdict, subject, payload}
    assert subject == "signals.analytics.predictions.cpu_usage:device-a:host-a"

    decoded = Jason.decode!(payload)
    finding_uid = decoded["finding_info"]["uid"]
    assert decoded["event_id"] == VerdictEmitter.event_id(@forecast)
    assert decoded["signal_type"] == "prediction"
    assert decoded["event_type"] == "capacity_forecast"
    assert decoded["status"] == "projected"
    assert decoded["finding_type"] == "detection"
    assert decoded["class_uid"] == 2004
    assert decoded["signal_domain"] == "health"
    assert decoded["severity_id"] == 5
    assert decoded["device_id"] == "device-a"
    assert decoded["device_uid"] == "device-a"
    assert decoded["finding_info"]["source"] == "capacity_forecasting"
    assert decoded["capacity_forecast"]["finding_uid"] == finding_uid
    refute Map.has_key?(decoded["capacity_forecast"], "clears_finding_uid")
    assert decoded["capacity_forecast"]["projected_exhaustion_at"] == "2026-06-12T22:00:00Z"
  end

  test "inactive capacity payload clears causal evidence" do
    subject = VerdictEmitter.subject(@forecast)
    payload = @forecast |> Map.put(:status, "inactive") |> VerdictEmitter.payload(subject)

    assert payload["status"] == "inactive"
    assert payload["severity_id"] == 2
    assert payload["message"] =~ "Capacity forecast cleared"
    assert payload["capacity_forecast"]["status"] == "inactive"
    assert payload["capacity_forecast"]["clears_finding_uid"] == payload["finding_info"]["uid"]
  end

  test "event identity ignores per-run forecast wall-clock fields" do
    next_run =
      Map.merge(@forecast, %{
        forecasted_at: ~U[2026-06-12 12:05:00Z],
        horizon_ends_at: ~U[2026-06-13 12:05:00Z],
        window_started_at: ~U[2026-06-01 00:05:00Z],
        window_ended_at: ~U[2026-06-02 23:05:00Z],
        projected_exhaustion_at: ~U[2026-06-12 22:05:00Z]
      })

    first_payload = VerdictEmitter.payload(@forecast)
    next_payload = VerdictEmitter.payload(next_run)

    assert first_payload["event_id"] == next_payload["event_id"]
    assert first_payload["finding_info"]["uid"] == next_payload["finding_info"]["uid"]
    assert first_payload["timestamp"] != next_payload["timestamp"]

    subject = VerdictEmitter.subject(@forecast)

    first_row =
      AnalyticsSignals.parse_message(%{
        data: Jason.encode!(first_payload),
        metadata: %{subject: subject, received_at: @forecast.forecasted_at}
      })

    next_row =
      AnalyticsSignals.parse_message(%{
        data: Jason.encode!(next_payload),
        metadata: %{subject: subject, received_at: next_run.forecasted_at}
      })

    assert first_row.id == next_row.id

    event_id = first_row.metadata["event_identity"]
    Process.put({:capacity_existing_ocsf_time, event_id}, first_row.time)

    assert [%{time: aligned_time}] =
             AnalyticsSignals.align_existing_ocsf_event_times([next_row], ExistingTimeRepo)

    assert DateTime.compare(aligned_time, first_row.time) == :eq
  end

  test "payload routes through the existing causal signal processor" do
    subject = VerdictEmitter.subject(@forecast)
    payload = VerdictEmitter.payload(@forecast, subject)

    row =
      AnalyticsSignals.parse_message(%{
        data: Jason.encode!(payload),
        metadata: %{subject: subject, received_at: @forecast.forecasted_at}
      })

    replayed_row =
      AnalyticsSignals.parse_message(%{
        data: Jason.encode!(payload),
        metadata: %{subject: subject, received_at: @forecast.forecasted_at}
      })

    assert row
    assert row.id == replayed_row.id
    assert row.class_uid == 2004
    assert row.type_uid == 200_401
    assert row.severity_id == 5
    assert row.severity == "Critical"
    assert row.device == %{"uid" => "device-a"}
    assert row.message =~ "Capacity forecast:"
    assert row.metadata["signal_type"] == "prediction"
    assert row.metadata["event_type"] == "capacity_forecast"
    assert row.metadata["primary_domain"] == "health"
    assert [alert_row] = AnalyticsSignals.alert_evaluation_rows([row])
    assert alert_row.id == row.metadata["event_identity"]
    assert row.unmapped["capacity_forecast"]["resource_key"] == @forecast.resource_key
  end
end
