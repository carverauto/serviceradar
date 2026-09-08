defmodule ServiceRadar.Observability.SeasonalDisposition.VerdictEmitterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.Observability.SeasonalDisposition.VerdictEmitter

  @moduletag :requires_app

  defmodule ExistingTimeRepo do
    def query(_sql, [ids]) do
      # Mirror the real DB: production binds 16-byte UUID binaries and `SELECT id::text`,
      # so canonicalize each bound binary to its string identity (the key the test stores
      # the persisted time under).
      rows =
        Enum.map(ids, fn id ->
          text_id = Ecto.UUID.load!(id)
          [text_id, Process.get({:seasonal_existing_ocsf_time, text_id})]
        end)

      {:ok, %{rows: rows}}
    end
  end

  @breach %{
    evaluated_at: ~U[2026-06-12 12:00:00Z],
    bucket_started_at: ~U[2026-06-09 09:00:00Z],
    bucket_ended_at: ~U[2026-06-09 10:00:00Z],
    series_key: "partition:p1:device:device-a:metric:cpu_usage",
    resource_type: "cpu",
    resource_id: "device-a",
    resource_label: "host-a / device-a",
    metric_class: "cpu",
    metric_name: "usage_percent",
    disposition: "seasonal_breach",
    score: 7.5,
    consecutive_anomalous: 3,
    dow: 2,
    hod: 9,
    sample_value: 95.0,
    status: "breach",
    metadata: %{"source" => "cpu_seasonal"}
  }

  test "publishes a deterministic seasonal causal signal" do
    publisher = fn subject, payload, _opts ->
      send(self(), {:published_seasonal_verdict, subject, payload})
      :ok
    end

    assert :ok = VerdictEmitter.emit(@breach, publisher: publisher)

    assert_received {:published_seasonal_verdict, subject, payload}

    assert subject ==
             "signals.analytics.predictions.partition:p1:device:device-a:metric:cpu_usage"

    decoded = Jason.decode!(payload)
    assert decoded["event_id"] == VerdictEmitter.event_id(@breach)
    assert decoded["signal_type"] == "prediction"
    assert decoded["event_type"] == "anomaly"
    assert decoded["verdict_source"] == "central-seasonal"
    assert decoded["status"] == "breach"
    assert decoded["finding_type"] == "detection"
    assert decoded["class_uid"] == 2004
    assert decoded["signal_domain"] == "health"
    assert decoded["severity_id"] == 3
    assert decoded["device_id"] == "device-a"
    assert decoded["device_uid"] == "device-a"
    assert decoded["finding_info"]["source"] == "seasonal_disposition"
    assert decoded["anomaly"]["state"] == "anomaly_open"
    assert decoded["anomaly"]["series_key"] == @breach.series_key
    assert decoded["anomaly"]["verdict_source"] == "central-seasonal"
    assert decoded["seasonal_disposition"]["bucket_ended_at"] == "2026-06-09T10:00:00Z"
  end

  test "inactive seasonal payload clears causal evidence" do
    subject = VerdictEmitter.subject(@breach)
    payload = @breach |> Map.put(:status, "cleared") |> VerdictEmitter.payload(subject)

    assert payload["status"] == "cleared"
    assert payload["severity_id"] == 2
    assert payload["message"] =~ "Seasonal anomaly cleared"
    assert payload["anomaly"]["state"] == "anomaly_clear"
    assert payload["anomaly"]["detector_state"] == "cleared"
    assert payload["seasonal_disposition"]["status"] == "cleared"
  end

  test "event identity ignores per-run seasonal wall-clock and hour-bucket fields" do
    next_run =
      Map.merge(@breach, %{
        evaluated_at: ~U[2026-06-12 12:05:00Z],
        bucket_started_at: ~U[2026-06-09 09:05:00Z],
        bucket_ended_at: ~U[2026-06-09 10:05:00Z],
        score: 7.8,
        sample_value: 96.0
      })

    first_payload = VerdictEmitter.payload(@breach)
    next_payload = VerdictEmitter.payload(next_run)

    assert first_payload["event_id"] == next_payload["event_id"]
    assert first_payload["finding_info"]["uid"] == next_payload["finding_info"]["uid"]
    assert first_payload["timestamp"] != next_payload["timestamp"]

    other_hour_payload = @breach |> Map.put(:hod, 10) |> VerdictEmitter.payload()
    assert first_payload["event_id"] == other_hour_payload["event_id"]
    assert first_payload["finding_info"]["uid"] == other_hour_payload["finding_info"]["uid"]

    subject = VerdictEmitter.subject(@breach)

    first_row =
      AnalyticsSignals.parse_message(%{
        data: Jason.encode!(first_payload),
        metadata: %{subject: subject, received_at: @breach.evaluated_at}
      })

    next_row =
      AnalyticsSignals.parse_message(%{
        data: Jason.encode!(next_payload),
        metadata: %{subject: subject, received_at: next_run.evaluated_at}
      })

    assert first_row.id == next_row.id

    event_id = first_row.metadata["event_identity"]
    Process.put({:seasonal_existing_ocsf_time, event_id}, first_row.time)

    assert [%{time: aligned_time}] =
             AnalyticsSignals.align_existing_ocsf_event_times([next_row], ExistingTimeRepo)

    assert DateTime.compare(aligned_time, first_row.time) == :eq
  end

  test "seasonal severity follows bounded bands and cannot mint Critical alone" do
    assert @breach
           |> Map.put(:score, 3.9)
           |> VerdictEmitter.payload()
           |> Access.get("severity_id") == 2

    assert @breach
           |> Map.put(:score, 4.0)
           |> VerdictEmitter.payload()
           |> Access.get("severity_id") == 3

    assert @breach
           |> Map.put(:score, 8.0)
           |> VerdictEmitter.payload()
           |> Access.get("severity_id") == 4

    assert @breach
           |> Map.put(:score, 100.0)
           |> VerdictEmitter.payload()
           |> Access.get("severity_id") == 4
  end
end
