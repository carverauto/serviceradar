defmodule ServiceRadar.Observability.StatefulAlertEngineTest do
  @moduledoc """
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.CausalSignals
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.OcsfEvent

  alias ServiceRadar.Observability.SeasonalDisposition.VerdictEmitter,
    as: SeasonalVerdictEmitter

  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleHistory
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", role: :admin}
    reset_engine()
    on_exit(&reset_engine/0)
    {:ok, actor: actor}
  end

  test "fires and resolves alerts based on bucketed counts", %{actor: actor} do
    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "sync-failures",
          enabled: true,
          signal: :event,
          match: %{"always" => true},
          group_by: ["serviceradar.sync.integration_source_id"],
          threshold: 2,
          window_seconds: 120,
          bucket_seconds: 60,
          cooldown_seconds: 60,
          renotify_seconds: 3600
        },
        actor: actor
      )
      |> Ash.create()

    base_time = DateTime.utc_now()

    event = fn timestamp ->
      %{
        id: Ash.UUID.generate(),
        time: timestamp,
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "sync failed",
        log_name: "sync",
        log_provider: "sync",
        unmapped: %{
          "log_attributes" => %{
            "serviceradar" => %{
              "sync" => %{
                "integration_source_id" => "source-1"
              }
            }
          }
        }
      }
    end

    events = [event.(base_time), event.(base_time)]

    # In single-deployment mode, schema is determined by search_path
    assert :ok = StatefulAlertEngine.evaluate_events(events)

    events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()

    threshold_event =
      Enum.find(events, fn event ->
        event.log_name == "alert.rule.threshold" and
          metadata_value(event.metadata, ["serviceradar", "rule_id"]) == to_string(rule.id)
      end)

    assert threshold_event

    alert =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.find(fn alert ->
        metadata_value(alert.metadata, ["event_id"]) == to_string(threshold_event.id)
      end)

    assert alert
    assert alert.status in [:pending, :acknowledged, :escalated]

    later = DateTime.add(base_time, 180, :second)
    assert :ok = StatefulAlertEngine.evaluate_events([event.(later)])

    {:ok, resolved} = Alert.get_by_id(alert.id, actor: actor)
    assert resolved.status == :resolved

    {:ok, history} =
      rule.id |> StatefulAlertRuleHistory.list_by_rule(actor: actor) |> Page.unwrap()

    assert Enum.any?(history, &(&1.event_type == :fired))
    assert Enum.any?(history, &(&1.event_type == :recovered))
  end

  test "fires metric alerts only for sustained baseline violations and recovers", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device_id = "pve-device-#{unique}"
    alert_title = "Proxmox CPU baseline #{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "proxmox-cpu-baseline-#{unique}",
          enabled: true,
          signal: :metric,
          match: %{
            "metric_name" => "proxmox_node_cpu_ratio_max",
            "device_id" => device_id,
            "condition" => %{
              "comparison" => "gt",
              "baseline_value" => 0.50,
              "baseline_offset" => 0.10
            }
          },
          group_by: ["device_id", "metric_name"],
          threshold: 3,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 60,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.metric.baseline",
            "message" => "Proxmox node CPU exceeded baseline"
          },
          alert: %{
            "title" => alert_title,
            "severity" => "warning"
          }
        },
        actor: actor
      )
      |> Ash.create()

    base_time = DateTime.utc_now()

    metric = fn timestamp, value ->
      %{
        timestamp: timestamp,
        gateway_id: "gw-1",
        agent_id: "agent-1",
        device_id: device_id,
        metric_name: "proxmox_node_cpu_ratio_max",
        metric_type: "plugin",
        value: value,
        unit: "ratio",
        tags: %{"cluster" => "lab"},
        metadata: %{"node" => "pve-1"},
        partition: "default"
      }
    end

    assert :ok =
             StatefulAlertEngine.evaluate_metrics([
               metric.(base_time, 0.62),
               metric.(DateTime.add(base_time, 60, :second), 0.66),
               metric.(DateTime.add(base_time, 120, :second), 0.70)
             ])

    threshold_events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.filter(fn event ->
        event.log_name == "alert.metric.baseline" and
          metadata_value(event.metadata, ["serviceradar", "rule_id"]) == to_string(rule.id)
      end)

    assert [threshold_event] = threshold_events
    assert threshold_event.unmapped["source_signal"] == "metric"
    assert threshold_event.unmapped["source_metric_name"] == "proxmox_node_cpu_ratio_max"
    assert threshold_event.unmapped["source_metric_condition"]["threshold"] == 0.60
    assert threshold_event.unmapped["source_metric_condition"]["baseline_value"] == 0.50

    active_alerts =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.filter(fn alert -> alert.title == alert_title end)

    assert [active_alert] = active_alerts

    assert active_alert.metadata["incident_group_values"] == %{
             "device_id" => device_id,
             "metric_name" => "proxmox_node_cpu_ratio_max"
           }

    assert active_alert.metadata["incident_window_count"] == 3
    assert active_alert.metadata["incident_diagnostics"]["source"]["source_signal"] == "metric"

    assert :ok =
             StatefulAlertEngine.evaluate_metrics([
               metric.(DateTime.add(base_time, 600, :second), 0.52)
             ])

    {:ok, resolved} = Alert.get_by_id(active_alert.id, actor: actor)
    assert resolved.status == :resolved

    history =
      rule.id
      |> StatefulAlertRuleHistory.list_by_rule(actor: actor)
      |> Page.unwrap!()

    assert Enum.any?(history, &(&1.event_type == :fired))
    assert Enum.any?(history, &(&1.event_type == :recovered))
  end

  test "groups endpoint vulnerability findings by OCSF device uid", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device_uid = "sr:endpoint-vuln-device-#{unique}"
    alert_title = "Endpoint vulnerability #{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "endpoint-vulnerability-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.causal.inventory",
            "attribute_equals" => %{"signal_type" => "inventory"}
          },
          group_by: ["device"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 60,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.security.endpoint_inventory.vulnerability",
            "message" => "Endpoint inventory vulnerability detected"
          },
          alert: %{
            "title" => alert_title,
            "severity" => "critical"
          }
        },
        actor: actor
      )
      |> Ash.create()

    event = %{
      id: Ash.UUID.generate(),
      time: DateTime.utc_now(),
      class_uid: 2004,
      category_uid: 2,
      type_uid: 200_401,
      activity_id: 1,
      severity_id: OCSF.severity_critical(),
      severity: OCSF.severity_name(OCSF.severity_critical()),
      message: "CVE matched installed package",
      log_name: "signals.causal.inventory.vulnerability",
      log_provider: "serviceradar.core",
      device: %{"uid" => device_uid},
      unmapped: %{
        "log_attributes" => %{
          "signal_type" => "inventory",
          "cve" => "CVE-2026-#{unique}",
          "package" => %{
            "name" => "nginx",
            "purl_canonical" => "pkg:deb/debian/nginx@1.24.0-2ubuntu7?arch=amd64"
          }
        }
      }
    }

    assert :ok = StatefulAlertEngine.evaluate_events([event])

    active_alerts =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.filter(fn alert -> alert.title == alert_title end)

    assert [active_alert] = active_alerts
    assert active_alert.metadata["incident_rule_id"] == to_string(rule.id)
    assert active_alert.metadata["incident_group_key"] == "device=#{device_uid}"
    assert active_alert.metadata["incident_group_values"] == %{"device" => device_uid}
  end

  test "causal prediction anomaly routes to ocsf_events and device-grouped alerts", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device_uid = "sr:anomaly-device-#{unique}"
    alert_title = "Anomaly detection #{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "anomaly-detection-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.causal.predictions",
            "attribute_equals" => %{"signal_type" => "causal", "event_type" => "anomaly"}
          },
          group_by: ["device"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 60,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.health.anomaly_detection",
            "message" => "Anomaly detection finding detected"
          },
          alert: %{
            "title" => alert_title,
            "severity" => "warning"
          }
        },
        actor: actor
      )
      |> Ash.create()

    observed_at = DateTime.to_unix(DateTime.utc_now(), :nanosecond)

    series_key = "sysmon:memory:#{device_uid}"
    subject = "signals.causal.predictions.#{series_key}"

    payload = %{
      "event_id" => "anomaly:sample-#{unique}:anomalous",
      "signal_type" => "causal",
      "event_type" => "anomaly",
      "status" => "open",
      "finding_type" => "detection",
      "class_uid" => 2004,
      "type_uid" => 200_401,
      "signal_domain" => "health",
      "signal_domains" => ["health"],
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "severity_id" => 4,
      "provider" => "anomaly_detection",
      "source" => "serviceradar",
      "collector" => "anomaly_addon",
      "device_uid" => device_uid,
      "message" => "Anomaly detected: sysmon.memory #{series_key}",
      "finding_info" => %{
        "uid" => "anomaly:#{unique}",
        "group_uid" => "anomaly:#{unique}",
        "title" => "Anomaly detection: sysmon.memory #{series_key}",
        "type" => "ServiceRadar Anomaly",
        "type_id" => 99,
        "source" => "anomaly_detection"
      },
      "anomaly" => %{
        "series_key" => series_key,
        "event_id" => "sample-#{unique}",
        "metric_class" => "sysmon.memory",
        "observed_at_unix_nano" => observed_at,
        "value" => 97.5,
        "state" => "anomalous",
        "reason" => "rolling z-score breached",
        "score" => 3.8,
        "baseline_count" => 48
      },
      "source_identity" => %{
        "entity_uid" => device_uid,
        "series_key" => series_key,
        "metric_class" => "sysmon.memory",
        "host_id" => "host-#{unique}"
      },
      "source_subject" => subject
    }

    broadway_message =
      Pipeline.transform(
        %{
          data: Jason.encode!(payload),
          metadata: %{subject: subject, received_at: DateTime.utc_now()},
          ack_data: %{}
        },
        []
      )

    message = Pipeline.handle_message(:default, broadway_message, %{})

    assert message.batcher == :causal_predictions
    assert CausalSignals.table_name() == "ocsf_events"

    row = CausalSignals.parse_message(%{data: message.data, metadata: message.metadata})

    assert row.class_uid == 2004
    assert row.type_uid == 200_401
    assert row.device == %{"uid" => device_uid}

    assert {:ok, 1} = CausalSignals.process_batch([message])
    assert persisted_ocsf_event?(row)

    active_alerts =
      eventually(
        fn ->
          Alert
          |> Ash.Query.for_read(:active, %{}, actor: actor)
          |> Ash.read!()
          |> Page.unwrap!()
          |> Enum.filter(fn alert -> alert.title == alert_title end)
        end,
        fn alerts -> match?([_], alerts) end
      )

    assert [active_alert] = active_alerts
    assert active_alert.metadata["incident_rule_id"] == to_string(rule.id)
    assert active_alert.metadata["incident_group_key"] == "device=#{device_uid}"
    assert active_alert.metadata["incident_group_values"] == %{"device" => device_uid}
  end

  test "causal anomaly alerts only on open transitions and resolves on clear", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device_uid = "sr:anomaly-alert-device-#{unique}"
    series_key = "sysmon:cpu:#{device_uid}:0"
    alert_title = "Anomaly transition #{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "anomaly-transition-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.causal.predictions",
            "attribute_equals" => %{
              "signal_type" => "causal",
              "event_type" => "anomaly",
              "anomaly.state" => ["anomaly_open", "open"]
            },
            "recovery" => %{
              "subject_prefix" => "signals.causal.predictions",
              "attribute_equals" => %{
                "signal_type" => "causal",
                "event_type" => "anomaly",
                "anomaly.state" => ["anomaly_clear", "inactive"]
              }
            }
          },
          group_by: ["device", "anomaly.series_key"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 300,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.health.anomaly_detection",
            "message" => "Anomaly detection finding detected"
          },
          alert: %{"title" => alert_title, "severity_from" => "source"}
        },
        actor: actor
      )
      |> Ash.create()

    base_time = DateTime.utc_now()

    event = fn state, offset ->
      %{
        id: Ash.UUID.generate(),
        time: DateTime.add(base_time, offset, :second),
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "Anomaly #{state}",
        log_name: "signals.causal.predictions.#{series_key}",
        log_provider: "anomaly_detection",
        device: %{"uid" => device_uid},
        unmapped: %{
          "signal_type" => "causal",
          "event_type" => "anomaly",
          "anomaly" => %{
            "state" => state,
            "series_key" => series_key,
            "metric_class" => "sysmon.cpu"
          }
        },
        metadata: %{"signal_type" => "causal", "event_type" => "anomaly"}
      }
    end

    assert :ok = StatefulAlertEngine.evaluate_events([event.("pending_anomaly", 0)])
    assert [] = active_alerts_by_title(actor, alert_title)

    assert :ok = StatefulAlertEngine.evaluate_events([event.("anomaly_open", 10)])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    assert active_alert.severity == :critical
    assert active_alert.metadata["incident_rule_id"] == to_string(rule.id)

    assert active_alert.metadata["incident_group_values"] == %{
             "anomaly.series_key" => series_key,
             "device" => device_uid
           }

    assert :ok = StatefulAlertEngine.evaluate_events([event.("anomaly_open", 20)])
    assert [same_alert] = active_alerts_by_title(actor, alert_title)
    assert same_alert.id == active_alert.id
    assert same_alert.metadata["incident_occurrence_count"] == 2

    assert :ok = StatefulAlertEngine.evaluate_events([event.("anomaly_clear", 30)])
    assert [] = active_alerts_by_title(actor, alert_title)

    {:ok, resolved_alert} = Alert.get_by_id(active_alert.id, actor: actor)
    assert resolved_alert.status == :resolved
  end

  test "seeded anomaly rule contract opens and resolves for seasonal verdict payloads", %{
    actor: actor
  } do
    with_engine_shards(1, fn ->
      unique = System.unique_integer([:positive])
      device_uid = "sr:seasonal-alert-device-#{unique}"
      series_key = "seasonal:cpu:#{device_uid}:0"

      {:ok, rule} =
        StatefulAlertRule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "seasonal-seeded-contract-#{unique}",
            enabled: true,
            signal: :event,
            match: %{
              "subject_prefix" => "signals.causal.predictions",
              "attribute_equals" => %{
                "signal_type" => "causal",
                "event_type" => ["anomaly", "anomaly_detection"],
                "anomaly.state" => ["anomaly_open", "open", "anomalous"]
              },
              "recovery" => %{
                "subject_prefix" => "signals.causal.predictions",
                "attribute_equals" => %{
                  "signal_type" => "causal",
                  "event_type" => ["anomaly", "anomaly_detection"],
                  "anomaly.state" => ["anomaly_clear", "clear", "cleared", "inactive"]
                }
              }
            },
            group_by: ["device", "anomaly.series_key"],
            threshold: 1,
            window_seconds: 300,
            bucket_seconds: 60,
            cooldown_seconds: 300,
            renotify_seconds: 21_600,
            event: %{
              "log_name" => "alert.health.causal_prediction",
              "message" => "Causal prediction finding detected"
            },
            alert: %{"title" => "Anomaly Finding", "severity_from" => "source"}
          },
          actor: actor
        )
        |> Ash.create()

      base_time = DateTime.utc_now()

      event = fn status, offset ->
        event_time = DateTime.add(base_time, offset, :second)

        seasonal_payload =
          status
          |> seasonal_verdict_attrs(device_uid, series_key, event_time)
          |> SeasonalVerdictEmitter.payload()

        severity_id = Map.fetch!(seasonal_payload, "severity_id")

        %{
          id: Ash.UUID.generate(),
          time: event_time,
          severity_id: severity_id,
          severity: OCSF.severity_name(severity_id),
          message: Map.fetch!(seasonal_payload, "message"),
          log_name: Map.fetch!(seasonal_payload, "source_subject"),
          log_provider: "seasonal_disposition",
          device: %{"uid" => device_uid},
          unmapped: seasonal_payload,
          metadata: %{"signal_type" => "causal", "event_type" => "anomaly"}
        }
      end

      assert :ok = StatefulAlertEngine.evaluate_events([event.("breach", 0)])

      active_alert =
        eventually(
          fn -> seasonal_alert_row(rule.id, device_uid, series_key) end,
          &match?(%{"status" => "pending"}, &1)
        )

      assert active_alert["title"] == "Anomaly Finding"
      assert active_alert["severity"] == "critical"

      assert :ok = StatefulAlertEngine.evaluate_events([event.("cleared", 60)])

      resolved_alert =
        eventually(
          fn -> seasonal_alert_row(rule.id, device_uid, series_key) end,
          &match?(%{"status" => "resolved"}, &1)
        )

      assert resolved_alert["id"] == active_alert["id"]
    end)
  end

  test "capacity forecast alerts coalesce by resource and resolve on inactive status", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device_uid = "sr:capacity-alert-device-#{unique}"
    resource_key = "disk_usage:#{device_uid}:/var"
    alert_title = "Capacity forecast #{unique}"

    {:ok, _rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "capacity-forecast-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.causal.predictions",
            "attribute_equals" => %{
              "signal_type" => "causal",
              "event_type" => "capacity_forecast",
              "capacity_forecast.status" => "projected"
            },
            "recovery" => %{
              "subject_prefix" => "signals.causal.predictions",
              "attribute_equals" => %{
                "signal_type" => "causal",
                "event_type" => "capacity_forecast",
                "capacity_forecast.status" => ["inactive", "skipped"]
              }
            }
          },
          group_by: ["device", "capacity_forecast.resource_key"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 300,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.health.capacity_forecast",
            "message" => "Capacity forecast warning-horizon finding detected"
          },
          alert: %{"title" => alert_title, "severity_from" => "source"}
        },
        actor: actor
      )
      |> Ash.create()

    base_time = DateTime.utc_now()

    event = fn status, offset ->
      %{
        id: Ash.UUID.generate(),
        time: DateTime.add(base_time, offset, :second),
        severity_id: OCSF.severity_critical(),
        severity: OCSF.severity_name(OCSF.severity_critical()),
        message: "Capacity forecast #{status}",
        log_name: "signals.causal.predictions.capacity.#{unique}",
        log_provider: "capacity_forecasting",
        device: %{"uid" => device_uid},
        unmapped: %{
          "signal_type" => "causal",
          "event_type" => "capacity_forecast",
          "capacity_forecast" => %{
            "status" => status,
            "resource_key" => resource_key,
            "resource_type" => "disk",
            "metric_name" => "usage_percent"
          }
        },
        metadata: %{"signal_type" => "causal", "event_type" => "capacity_forecast"}
      }
    end

    assert :ok = StatefulAlertEngine.evaluate_events([event.("inactive", 0)])
    assert [] = active_alerts_by_title(actor, alert_title)

    assert :ok = StatefulAlertEngine.evaluate_events([event.("projected", 10)])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    assert active_alert.severity == :critical

    assert active_alert.metadata["incident_group_values"] == %{
             "capacity_forecast.resource_key" => resource_key,
             "device" => device_uid
           }

    assert :ok = StatefulAlertEngine.evaluate_events([event.("projected", 20)])
    assert [same_alert] = active_alerts_by_title(actor, alert_title)
    assert same_alert.id == active_alert.id
    assert same_alert.metadata["incident_occurrence_count"] == 2

    assert :ok = StatefulAlertEngine.evaluate_events([event.("inactive", 30)])
    assert [] = active_alerts_by_title(actor, alert_title)

    {:ok, resolved_alert} = Alert.get_by_id(active_alert.id, actor: actor)
    assert resolved_alert.status == :resolved
  end

  test "deduplicates repeated event bursts into one active incident and rolls over after cooldown gap",
       %{actor: actor} do
    unique = System.unique_integer([:positive])
    subject = "falco.test.#{unique}"
    title = "Falco Security Incident #{unique}"
    rule_name = "Drop and execute new binary in container #{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "falco-incident-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => subject,
            "severity_number_min" => OCSF.severity_critical()
          },
          group_by: ["rule", "hostname"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 300,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.security.falco.incident",
            "message" => "Falco security incident detected"
          },
          alert: %{
            "title" => title,
            "severity" => "critical"
          }
        },
        actor: actor
      )
      |> Ash.create()

    base_time = DateTime.utc_now()

    event = fn timestamp ->
      event_id = Ash.UUID.generate()

      diagnostics = %{
        "rule" => %{
          "name" => rule_name,
          "priority" => "Critical"
        },
        "host" => %{"name" => "core-elx"},
        "process" => %{
          "name" => "tool",
          "command" => "/tmp/.build/tool --lint",
          "cwd" => "/workspace/carverauto/serviceradar",
          "executable_flags" => %{"upper_layer" => true, "from_memfd" => false}
        },
        "parent_process" => %{"name" => "bash"},
        "container" => %{
          "id" => "d2d34c8e90ab",
          "name" => "forgejo-runner",
          "image_repository" => "code.forgejo.org/forgejo/runner",
          "image_tag" => "latest"
        },
        "kubernetes" => %{},
        "attribution" => %{
          "status" => "partial",
          "missing" => ["kubernetes.namespace", "kubernetes.pod"]
        }
      }

      %{
        id: event_id,
        time: timestamp,
        severity_id: OCSF.severity_critical(),
        severity: OCSF.severity_name(OCSF.severity_critical()),
        message: "Drop and execute new binary in container",
        log_name: subject,
        log_provider: "falco",
        metadata: %{
          "subject" => subject,
          "rule" => rule_name,
          "hostname" => "core-elx",
          "security_signal" => %{
            "kind" => "runtime",
            "source" => "falco",
            "diagnostics" => diagnostics
          }
        },
        unmapped: %{
          "rule" => rule_name,
          "hostname" => "core-elx",
          "falco" => %{
            "diagnostics" => diagnostics,
            "output_fields" => %{"proc.cmdline" => "/tmp/.build/tool --lint"}
          }
        }
      }
    end

    assert :ok = StatefulAlertEngine.evaluate_events([event.(base_time)])

    assert :ok =
             StatefulAlertEngine.evaluate_events([event.(DateTime.add(base_time, 30, :second))])

    assert :ok =
             StatefulAlertEngine.evaluate_events([event.(DateTime.add(base_time, 90, :second))])

    alerts =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.filter(fn alert -> alert.title == title end)

    assert [active_alert] = alerts
    assert active_alert.metadata["incident_rule_id"] == to_string(rule.id)

    assert active_alert.metadata["incident_group_values"] == %{
             "hostname" => "core-elx",
             "rule" => rule_name
           }

    assert active_alert.metadata["incident_occurrence_count"] == 3

    diagnostics = active_alert.metadata["incident_diagnostics"]

    assert diagnostics["rule_id"] == to_string(rule.id)
    assert diagnostics["rule_name"] == "falco-incident-#{unique}"
    assert diagnostics["threshold"] == 1
    assert diagnostics["window_seconds"] == 300
    assert diagnostics["window_count"] == 3
    assert length(diagnostics["representative_event_ids"]) == 3

    assert [
             %{
               "name" => "tool",
               "parent" => "bash",
               "command" => "/tmp/.build/tool --lint",
               "cwd" => "/workspace/carverauto/serviceradar",
               "executable_flags" => %{"upper_layer" => true, "from_memfd" => false}
             }
             | _
           ] = diagnostics["samples"]["processes"]

    assert [
             %{
               "id" => "d2d34c8e90ab",
               "name" => "forgejo-runner",
               "image_repository" => "code.forgejo.org/forgejo/runner",
               "image_tag" => "latest"
             }
             | _
           ] = diagnostics["samples"]["containers"]

    assert [
             %{
               "attribution_status" => "partial",
               "missing" => ["kubernetes.namespace", "kubernetes.pod"]
             }
             | _
           ] = diagnostics["samples"]["kubernetes"]

    history =
      rule.id
      |> StatefulAlertRuleHistory.list_by_rule(actor: actor)
      |> Page.unwrap!()

    assert Enum.count(Enum.filter(history, &(&1.event_type == :fired))) == 1
    refute Enum.any?(history, &(&1.event_type == :cooldown))

    rollover_time = DateTime.add(base_time, 420, :second)
    assert :ok = StatefulAlertEngine.evaluate_events([event.(rollover_time)])

    active_alerts_after_rollover =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.filter(fn alert -> alert.title == title end)

    assert [replacement_alert] = active_alerts_after_rollover
    refute replacement_alert.id == active_alert.id
    assert replacement_alert.metadata["incident_occurrence_count"] == 1

    {:ok, resolved_original_alert} = Alert.get_by_id(active_alert.id, actor: actor)
    assert resolved_original_alert.status == :resolved

    rollover_history =
      rule.id
      |> StatefulAlertRuleHistory.list_by_rule(actor: actor)
      |> Page.unwrap!()

    assert Enum.count(Enum.filter(rollover_history, &(&1.event_type == :fired))) == 2
    assert Enum.any?(rollover_history, &(&1.event_type == :recovered))
  end

  test "fans out across shards so rules in different shards fire concurrently and independently",
       %{actor: actor} do
    # Create enough rules that at least two land in distinct shards, then drive
    # them in a single batch. The previous single-GenServer engine processed
    # every rule serially behind one process (blocking on each rule's DB
    # writes). The sharded engine runs disjoint rules in separate processes, so
    # this proves DB writes no longer funnel through a single serialization
    # point while every rule still fires exactly once.
    unique = System.unique_integer([:positive])

    rules =
      for index <- 1..6 do
        title = "Shard fanout #{unique}-#{index}"

        {:ok, rule} =
          StatefulAlertRule
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "shard-fanout-#{unique}-#{index}",
              enabled: true,
              signal: :event,
              match: %{"attribute_equals" => %{"fanout_index" => to_string(index)}},
              group_by: ["fanout_index"],
              threshold: 1,
              window_seconds: 300,
              bucket_seconds: 60,
              cooldown_seconds: 60,
              renotify_seconds: 3600,
              event: %{
                "log_name" => "alert.test.shard_fanout",
                "message" => "Shard fanout finding"
              },
              alert: %{"title" => title, "severity" => "warning"}
            },
            actor: actor
          )
          |> Ash.create()

        {index, title, rule}
      end

    shards =
      rules
      |> Enum.map(fn {_index, _title, rule} ->
        StatefulAlertEngine.shard_for_rule_id(rule.id)
      end)
      |> Enum.uniq()

    # Guard the premise: the batch must exercise more than one shard for this to
    # be a meaningful concurrency test.
    assert length(shards) > 1,
           "expected rules to span multiple shards, got #{inspect(shards)}"

    events =
      for {index, _title, _rule} <- rules do
        %{
          id: Ash.UUID.generate(),
          time: DateTime.utc_now(),
          severity_id: OCSF.severity_high(),
          severity: OCSF.severity_name(OCSF.severity_high()),
          message: "fanout event #{index}",
          log_name: "fanout",
          log_provider: "fanout",
          unmapped: %{
            "log_attributes" => %{"fanout_index" => to_string(index)}
          }
        }
      end

    assert :ok = StatefulAlertEngine.evaluate_events(events)

    active_alerts =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()

    # Every rule fired exactly once.
    for {_index, title, _rule} <- rules do
      assert Enum.count(active_alerts, fn alert -> alert.title == title end) == 1,
             "expected exactly one active alert titled #{title}"
    end
  end

  defp active_alerts_by_title(actor, title) do
    Alert
    |> Ash.Query.for_read(:active, %{}, actor: actor)
    |> Ash.read!()
    |> Page.unwrap!()
    |> Enum.filter(fn alert -> alert.title == title end)
  end

  defp seasonal_verdict_attrs(status, device_uid, series_key, bucket_ended_at) do
    bucket_started_at = DateTime.add(bucket_ended_at, -3600, :second)

    %{
      status: status,
      disposition: if(status == "breach", do: "seasonal_breach", else: "suppressed"),
      resource_type: "device",
      resource_id: device_uid,
      resource_label: device_uid,
      series_key: series_key,
      metric_class: "sysmon.cpu",
      metric_name: "cpu.usage_percent",
      score: if(status == "breach", do: 7.25, else: 0.5),
      consecutive_anomalous: if(status == "breach", do: 3, else: 0),
      dow: 2,
      hod: 10,
      sample_value: if(status == "breach", do: 97.0, else: 31.0),
      evaluated_at: bucket_ended_at,
      bucket_started_at: bucket_started_at,
      bucket_ended_at: bucket_ended_at,
      metadata: %{"source" => "cpu_seasonal"}
    }
  end

  defp seasonal_alert_row(rule_id, device_uid, series_key) do
    sql = """
    SELECT id::text, title, status, severity
    FROM platform.alerts
    WHERE title = 'Anomaly Finding'
      AND metadata ->> 'incident_rule_id' = $1
      AND metadata -> 'incident_group_values' ->> 'device' = $2
      AND metadata -> 'incident_group_values' ->> 'anomaly.series_key' = $3
    ORDER BY created_at DESC
    LIMIT 1
    """

    case ServiceRadar.Repo.query!(sql, [to_string(rule_id), device_uid, series_key]).rows do
      [[id, title, status, severity]] ->
        %{"id" => id, "title" => title, "status" => status, "severity" => severity}

      [] ->
        nil
    end
  end

  defp with_engine_shards(count, fun) when is_integer(count) and count > 0 do
    previous = Application.get_env(:serviceradar_core, :stateful_alert_engine_shards)
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, count)
    reset_engine()

    try do
      fun.()
    after
      reset_engine()

      case previous do
        nil -> Application.delete_env(:serviceradar_core, :stateful_alert_engine_shards)
        value -> Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, value)
      end
    end
  end

  defp reset_engine do
    # The engine is sharded; terminate every shard so in-memory ETS state does
    # not leak between tests. Shard 0 keeps the legacy `:stateful_alert_engine`
    # registry key; the rest use `{:stateful_alert_engine, shard}`.
    shard_count = StatefulAlertEngine.shard_count()

    keys =
      [:stateful_alert_engine] ++
        for shard <- 1..(shard_count - 1)//1, do: {:stateful_alert_engine, shard}

    terminated? =
      Enum.reduce(keys, false, fn key, acc ->
        case ProcessRegistry.lookup(key) do
          [{pid, _}] ->
            _ = ProcessRegistry.terminate_child(pid)
            true

          _ ->
            acc
        end
      end)

    if terminated?, do: Process.sleep(25)
    :ok
  end

  defp eventually(fun, predicate, attempts \\ 40)

  defp eventually(fun, predicate, attempts) when attempts > 0 do
    value = fun.()

    if predicate.(value) do
      value
    else
      Process.sleep(25)
      eventually(fun, predicate, attempts - 1)
    end
  end

  defp eventually(fun, _predicate, 0), do: fun.()

  defp metadata_value(data, [key]), do: metadata_value(data, key)

  defp metadata_value(data, [key | rest]) when is_map(data) do
    case metadata_value(data, key) do
      %{} = nested -> metadata_value(nested, rest)
      _ -> nil
    end
  end

  defp metadata_value(data, key) when is_map(data) and is_binary(key) do
    Map.get(data, key) || Map.get(data, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(data, key)
  end

  defp metadata_value(data, key) when is_map(data) and is_atom(key) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil

  defp persisted_ocsf_event?(%{id: id, time: %DateTime{} = time}) do
    {:ok, uuid} = uuid_query_param(id)

    case ServiceRadar.Repo.query(
           "SELECT 1 FROM platform.ocsf_events WHERE id = $1::uuid AND time = $2 LIMIT 1",
           [uuid, time]
         ) do
      {:ok, %{num_rows: 1}} -> true
      _ -> false
    end
  end

  defp uuid_query_param(<<_::128>> = uuid), do: {:ok, uuid}
  defp uuid_query_param(id) when is_binary(id), do: Ecto.UUID.dump(id)
end
