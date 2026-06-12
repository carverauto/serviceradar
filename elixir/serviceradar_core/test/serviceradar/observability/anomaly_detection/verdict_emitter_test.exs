defmodule ServiceRadar.Observability.AnomalyDetection.VerdictEmitterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.CausalSignals
  alias ServiceRadar.Observability.AnomalyDetection.VerdictEmitter

  @sample %{
    series_key: "sysmon:memory:host-a",
    event_id: "00000645-50df-8e80-8000-000000000002",
    order_key: "00000645-50df-8e80-8000-000000000002",
    value: 97.5,
    observed_at_unix_nano: 1_781_260_800_000_000_000,
    subject: "metrics.sysmon.memory",
    metric_class: "sysmon.memory",
    metadata: %{"host_id" => "host-a", "used_bytes" => 975, "total_bytes" => 1_000}
  }

  @verdict %{
    state: "anomalous",
    anomalous: true,
    breached: true,
    include_in_baseline: false,
    next_consecutive_anomalous: 5,
    score: 3.8,
    reason: "rolling z-score breached",
    baseline_count: 48,
    sample_value: 97.5,
    observed_at_unix_nano: 1_781_260_800_000_000_000,
    signals: [
      %{
        name: "rolling",
        enabled: true,
        ready: true,
        breached: true,
        score: 3.8,
        threshold: 3.0,
        sample_count: 48,
        mean: 40.0,
        stddev: 15.0,
        reason: "breached"
      }
    ]
  }

  test "publishes deterministic anomaly verdicts on the causal prediction subject" do
    publisher = fn subject, payload, _opts ->
      send(self(), {:published_anomaly_verdict, subject, payload})
      :ok
    end

    assert :ok = VerdictEmitter.emit(@sample, @verdict, publisher: publisher)

    assert_received {:published_anomaly_verdict, subject, payload}
    assert subject == "signals.causal.predictions.sysmon:memory:host-a"

    decoded = Jason.decode!(payload)
    assert decoded["event_id"] == VerdictEmitter.event_id(@sample, @verdict)
    assert decoded["signal_type"] == "causal"
    assert decoded["event_type"] == "anomaly"
    assert decoded["status"] == "open"
    assert decoded["class_uid"] == 2004
    assert decoded["device_uid"] == "host-a"
    assert decoded["severity_id"] == 4
    assert decoded["finding_info"]["uid"]
    assert decoded["finding_info"]["group_uid"] == decoded["finding_info"]["uid"]
    assert decoded["finding_info"]["dimensions"]["device_uid"] == "host-a"
    assert decoded["finding_info"]["dimensions"]["series_key"] == "sysmon:memory:host-a"
    assert decoded["anomaly"]["series_key"] == "sysmon:memory:host-a"
    assert decoded["anomaly"]["state"] == "anomalous"
  end

  test "anomaly payload routes through CausalSignals as an OCSF detection finding" do
    subject = VerdictEmitter.subject(@sample)
    payload = VerdictEmitter.payload(@sample, @verdict, subject)

    replay_payload =
      @sample
      |> Map.put(:event_id, "00000645-50df-8e80-8000-000000000099")
      |> VerdictEmitter.payload(@verdict, subject)

    row =
      CausalSignals.parse_message(%{
        data: Jason.encode!(payload),
        metadata: %{subject: subject, received_at: DateTime.utc_now()}
      })

    replayed_row =
      CausalSignals.parse_message(%{
        data: Jason.encode!(payload),
        metadata: %{subject: subject, received_at: DateTime.utc_now()}
      })

    replay_event_row =
      CausalSignals.parse_message(%{
        data: Jason.encode!(replay_payload),
        metadata: %{subject: subject, received_at: DateTime.utc_now()}
      })

    assert row
    assert row.id == replayed_row.id
    assert row.id != replay_event_row.id
    assert row.class_uid == 2004
    assert row.category_uid == 2
    assert row.type_uid == 200_401
    assert row.activity_id == 1
    assert row.activity_name == "Create"
    assert row.severity_id == 4
    assert row.severity == "High"
    assert row.device == %{"uid" => "host-a"}
    assert row.metadata["signal_type"] == "causal"
    assert row.metadata["event_type"] == "anomaly"
    assert row.metadata["primary_domain"] == "health"
    assert row.metadata["service_radar"]["source_type"] == "anomaly_detection"
    assert row.metadata["service_radar"]["ocsf_class"] == "detection_finding"
    assert row.metadata["service_radar"]["finding_uid"] == row.metadata["finding_info"]["uid"]
    assert row.metadata["security_signal"]["finding_uid"] == row.metadata["finding_info"]["uid"]
    assert row.metadata["detection_finding"]["series_key"] == @sample.series_key
    assert row.metadata["finding_info"]["uid"] == replay_event_row.metadata["finding_info"]["uid"]
    assert row.metadata["finding_info"]["dimensions"]["device_uid"] == "host-a"
    assert row.unmapped["anomaly"]["reason"] == "rolling z-score breached"
  end
end
