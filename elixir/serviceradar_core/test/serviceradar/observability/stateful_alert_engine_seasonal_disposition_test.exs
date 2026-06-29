defmodule ServiceRadar.Observability.StatefulAlertEngineSeasonalDispositionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Observability.StatefulAlertEngine

  test "unsupported edge-spike metric classes are not suppressed by seasonal disposition" do
    rule = anomaly_open_rule()
    time = DateTime.truncate(DateTime.utc_now(), :microsecond)

    for {metric_class, metric_name} <- [
          {"snmp.interface", "ifInOctets"},
          {"sysmon.process", "process.cpu_percent"},
          {"disk", "usage_percent"}
        ] do
      refute StatefulAlertEngine.seasonal_disposition_suppresses_edge_anomaly?(
               anomaly_event(metric_class, metric_name, time),
               rule
             )

      assert StatefulAlertEngine.seasonal_disposition_action_for_edge_anomaly(
               anomaly_event(metric_class, metric_name, time),
               rule
             ) == :pass_through
    end
  end

  test "seasonal disposition rows map to explicit edge actions" do
    for disposition <- [
          %{disposition: "normal", status: "normal"},
          %{disposition: "suppress", status: "suppressed"}
        ] do
      assert StatefulAlertEngine.seasonal_disposition_action(disposition) == :suppress
    end

    for disposition <- [
          %{disposition: "seasonal_breach", status: "breach"},
          %{disposition: "off_baseline", status: "off_baseline"},
          %{disposition: "anomalous", status: "anomalous"}
        ] do
      assert StatefulAlertEngine.seasonal_disposition_action(disposition) == :escalate
    end

    for disposition <- [
          nil,
          %{disposition: "insufficient_seasonal_baseline", status: "insufficient"},
          %{disposition: "pending", status: "pending"}
        ] do
      assert StatefulAlertEngine.seasonal_disposition_action(disposition) == :pass_through
    end
  end

  test "edge anomaly disposition tagging records operator context and escalates severity" do
    time = DateTime.truncate(DateTime.utc_now(), :microsecond)
    event = anomaly_event("sysmon.cpu", "usage_percent", time)

    tagged =
      StatefulAlertEngine.tag_edge_anomaly_disposition(
        event,
        :escalate,
        %{
          series_key: "sysmon.cpu:sr:test-device:usage_percent",
          metric_class: "sysmon.cpu"
        },
        %{
          disposition: "seasonal_breach",
          status: "breach",
          score: 4.8,
          evaluated_at: time,
          bucket_started_at: DateTime.add(time, -3600, :second),
          bucket_ended_at: time
        }
      )

    assert tagged.severity_id == OCSF.severity_critical()
    assert tagged.severity == OCSF.severity_name(OCSF.severity_critical())

    metadata_disposition = tagged.metadata["service_radar"]["anomaly_disposition"]
    unmapped_disposition = tagged.unmapped["anomaly_disposition"]

    assert metadata_disposition == unmapped_disposition
    assert metadata_disposition["action"] == "escalate"
    assert metadata_disposition["seasonal_disposition"] == "seasonal_breach"
    assert metadata_disposition["seasonal_status"] == "breach"
    assert metadata_disposition["seasonal_score"] == 4.8
  end

  defp anomaly_open_rule do
    %{
      signal: :event,
      match: %{
        "subject_prefix" => "signals.analytics.predictions",
        "attribute_equals" => %{
          "signal_type" => "prediction",
          "event_type" => ["anomaly", "anomaly_detection"],
          "anomaly.state" => ["anomaly_open", "open", "anomalous"]
        }
      }
    }
  end

  defp anomaly_event(metric_class, metric_name, time) do
    series_key = "#{metric_class}:sr:test-device:#{metric_name}"

    %{
      id: Ash.UUID.generate(),
      time: time,
      severity_id: OCSF.severity_high(),
      severity: OCSF.severity_name(OCSF.severity_high()),
      message: "Anomaly edge-spike",
      log_name: "signals.analytics.predictions.#{series_key}",
      log_provider: "anomaly_detection",
      device: %{"uid" => "sr:test-device"},
      unmapped: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "verdict_source" => "edge-spike",
        "anomaly" => %{
          "state" => "anomaly_open",
          "series_key" => series_key,
          "metric_class" => metric_class,
          "metric_name" => metric_name,
          "verdict_source" => "edge-spike"
        }
      },
      metadata: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "service_radar" => %{"verdict_source" => "edge-spike"}
      }
    }
  end
end
