defmodule ServiceRadar.Observability.MtrCausalSignalEmitterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrCausalSignalEmitter

  test "build_normalized_envelope includes topology join keys" do
    consensus = %{
      classification: :path_scoped_issue,
      confidence: 0.9,
      evidence: %{votes: %{p_unreachable: 0.5, p_success: 0.5}}
    }

    context = %{
      "incident_correlation_id" => "inc-123",
      "target_device_uid" => "dev-123",
      "target_ip" => "8.8.8.8",
      "partition_id" => "p1",
      "source_agent_ids" => ["a1", "a2"]
    }

    outcomes = [%{"agent_id" => "a1"}, %{"agent_id" => "a2"}]

    envelope =
      MtrCausalSignalEmitter.build_normalized_envelope(
        consensus,
        context,
        outcomes,
        Ecto.UUID.generate()
      )

    assert envelope["signal_type"] == "mtr"
    assert envelope["event_type"] == "path_scoped_issue"
    assert envelope["routing_correlation"]["target_device_uid"] == "dev-123"
    assert envelope["routing_correlation"]["target_ip"] == "8.8.8.8"
    assert envelope["routing_correlation"]["partition_id"] == "p1"
    assert envelope["routing_correlation"]["topology_keys"]["target_device_uid"] == "dev-123"
    assert envelope["routing_correlation"]["topology_keys"]["target_ip"] == "8.8.8.8"
    assert envelope["routing_correlation"]["topology_keys"]["partition_id"] == "p1"
  end

  test "build_ocsf_event_row maps envelope into ocsf fields" do
    event_identity = Ecto.UUID.generate()

    envelope = %{
      "schema_version" => "1.0",
      "signal_type" => "mtr",
      "event_type" => "target_outage",
      "severity_id" => 6,
      "event_identity" => event_identity,
      "event_time" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      "routing_correlation" => %{
        "target_device_uid" => "dev-1",
        "target_ip" => "1.1.1.1"
      }
    }

    row = MtrCausalSignalEmitter.build_ocsf_event_row(envelope)

    assert row.class_uid == 1008
    assert row.category_uid == 1
    assert row.type_uid == 1_008_003
    assert row.severity_id == 6
    assert row.severity == "critical"
    assert row.device["uid"] == "dev-1"
    assert row.device["ip"] == "1.1.1.1"
    assert row.log_name == "internal.causal.mtr"
    assert row.log_provider == "serviceradar"
  end
end
