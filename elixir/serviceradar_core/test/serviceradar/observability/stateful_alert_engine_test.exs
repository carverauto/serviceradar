defmodule ServiceRadar.Observability.StatefulAlertEngineTest do
  @moduledoc """
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Observability.AnomalyAlertLivenessCheck
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Observability.SeasonalDisposition.StateStore, as: SeasonalStateStore
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleHistory
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", role: :admin}
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
    assert :ok = evaluate_events_and_complete!(events)

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

    later = DateTime.shift(base_time, minute: 3)
    assert :ok = evaluate_events_and_complete!([event.(later)])

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
             evaluate_metrics_and_complete!([
               metric.(base_time, 0.62),
               metric.(DateTime.shift(base_time, minute: 1), 0.66),
               metric.(DateTime.shift(base_time, minute: 2), 0.70)
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
             evaluate_metrics_and_complete!([
               metric.(DateTime.shift(base_time, minute: 10), 0.52)
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
            "subject_prefix" => "signals.analytics.inventory",
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
      log_name: "signals.analytics.inventory.vulnerability",
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

    assert :ok = evaluate_events_and_complete!([event])

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
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{"signal_type" => "prediction", "event_type" => "anomaly"}
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
    subject = "signals.analytics.predictions.#{series_key}"

    payload = %{
      "event_id" => "anomaly:sample-#{unique}:anomalous",
      "signal_type" => "prediction",
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

    assert message.batcher == :analytics_predictions
    assert AnalyticsSignals.table_name() == "ocsf_events"

    row = AnalyticsSignals.parse_message(%{data: message.data, metadata: message.metadata})

    assert row.class_uid == 2004
    assert row.type_uid == 200_401
    assert row.device == %{"uid" => device_uid}

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    TestSupport.complete_alert_effects!()
    # The episode registry (default-on) stamps a deterministic transition
    # identity onto anomaly rows, so look the persisted row up by device
    # rather than by the pre-registry (id, time) pair.
    assert persisted_anomaly_event_for_device?(device_uid)

    # The async queue path persists the alert and then syncs incident metadata
    # as a separate write, so wait until the active alert exists AND its incident
    # metadata is populated (the conditions the assertions below depend on)
    # rather than just for the alert row to appear.
    active_alerts =
      eventually(
        fn ->
          Alert
          |> Ash.Query.for_read(:active, %{}, actor: actor)
          |> Ash.read!()
          |> Page.unwrap!()
          |> Enum.filter(fn alert -> alert.title == alert_title end)
        end,
        fn
          [alert] -> alert.metadata["incident_rule_id"] == to_string(rule.id)
          _ -> false
        end
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
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => "anomaly",
              "anomaly.state" => ["anomaly_open", "open"]
            },
            "recovery" => %{
              "subject_prefix" => "signals.analytics.predictions",
              "attribute_equals" => %{
                "signal_type" => "prediction",
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
        time: DateTime.shift(base_time, second: offset),
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "Anomaly #{state}",
        log_name: "signals.analytics.predictions.#{series_key}",
        log_provider: "anomaly_detection",
        device: %{"uid" => device_uid},
        unmapped: %{
          "signal_type" => "prediction",
          "event_type" => "anomaly",
          "anomaly" => %{
            "state" => state,
            "series_key" => series_key,
            "metric_class" => "sysmon.cpu"
          }
        },
        metadata: %{"signal_type" => "prediction", "event_type" => "anomaly"}
      }
    end

    assert :ok = evaluate_events_and_complete!([event.("pending_anomaly", 0)])
    assert [] = active_alerts_by_title(actor, alert_title)

    assert :ok = evaluate_events_and_complete!([event.("anomaly_open", 10)])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    assert active_alert.severity == :critical
    assert active_alert.metadata["incident_rule_id"] == to_string(rule.id)

    assert active_alert.metadata["incident_group_values"] == %{
             "anomaly.series_key" => series_key,
             "device" => device_uid
           }

    assert :ok = evaluate_events_and_complete!([event.("anomaly_open", 20)])
    assert [same_alert] = active_alerts_by_title(actor, alert_title)
    assert same_alert.id == active_alert.id
    assert same_alert.metadata["incident_occurrence_count"] == 2

    assert :ok = evaluate_events_and_complete!([event.("anomaly_clear", 30)])
    assert [] = active_alerts_by_title(actor, alert_title)

    {:ok, resolved_alert} = Alert.get_by_id(active_alert.id, actor: actor)
    assert resolved_alert.status == :resolved
  end

  test "anomaly alert liveness check fires, resolves, and discards synthetic artifacts", %{
    actor: actor
  } do
    now = DateTime.utc_now()
    series_key = "synthetic:anomaly-alert-liveness:test:#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             run_liveness_and_complete!(
               actor: actor,
               now: now,
               series_key: series_key,
               timeout_ms: 1_000
             )

    assert result.series_key == series_key
    assert result.device_uid == "sr:anomaly-alert-liveness"
    assert result.resolved_at

    assert {:error, _reason} = Alert.get_by_id(result.alert_id, actor: actor)

    events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()

    refute Enum.any?(events, fn event ->
             event.log_name == "alert.health.causal_prediction" and
               get_in(event.unmapped || %{}, ["group_values", "anomaly.series_key"]) == series_key
           end)
  end

  test "recovery on an already-terminal alert is an idempotent no-op (no KeyError, no re-resolve)",
       %{actor: actor} do
    # Regression for two live-demo errors that share the recovery path:
    #   1. maybe_flush_snapshot read snapshot.bucket_changed directly, but the
    #      recover_event snapshot is rebuilt without :bucket_changed -> KeyError
    #      ("Stateful alert evaluation failed").
    #   2. resolve_alert re-fired the :resolve transition on an already-:resolved
    #      alert -> AshStateMachine NoMatchingTransition (resolved->resolved) log
    #      spam plus a duplicate :recovered history row on every retry.
    # Driving open -> out-of-band resolve -> clear exercises both: the clear runs
    # recover_event (snapshot lacks :bucket_changed) and calls resolve_alert with
    # the still-bound, now-terminal alert_id.
    unique = System.unique_integer([:positive])
    device_uid = "sr:idempotent-recovery-device-#{unique}"
    series_key = "sysmon:cpu:#{device_uid}:0"
    alert_title = "Idempotent recovery #{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "idempotent-recovery-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => "anomaly",
              "anomaly.state" => ["anomaly_open", "open"]
            },
            "recovery" => %{
              "subject_prefix" => "signals.analytics.predictions",
              "attribute_equals" => %{
                "signal_type" => "prediction",
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
        time: DateTime.shift(base_time, second: offset),
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "Anomaly #{state}",
        log_name: "signals.analytics.predictions.#{series_key}",
        log_provider: "anomaly_detection",
        device: %{"uid" => device_uid},
        unmapped: %{
          "signal_type" => "prediction",
          "event_type" => "anomaly",
          "anomaly" => %{
            "state" => state,
            "series_key" => series_key,
            "metric_class" => "sysmon.cpu"
          }
        },
        metadata: %{"signal_type" => "prediction", "event_type" => "anomaly"}
      }
    end

    # Open the alert; the ETS snapshot now holds a bound, active alert_id.
    assert :ok = evaluate_events_and_complete!([event.("anomaly_open", 0)])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    # Resolve the alert out-of-band (REST/sweep/duplicate clear), leaving the ETS
    # snapshot still referencing the now-terminal alert_id. The engine recorded no
    # :recovered history for this path.
    {:ok, resolved} =
      active_alert
      |> Ash.Changeset.for_update(:resolve, %{resolved_by: "out-of-band"}, actor: actor)
      |> Ash.update()

    assert resolved.status == :resolved
    assert [] = active_alerts_by_title(actor, alert_title)

    recovered_before =
      rule.id
      |> StatefulAlertRuleHistory.list_by_rule(actor: actor)
      |> Page.unwrap!()
      |> Enum.count(&(&1.event_type == :recovered))

    # The clear event drives recover_event -> handle_recovery -> resolve_alert on the
    # already-:resolved alert. Pre-fix this raised KeyError (#1) / NoMatchingTransition
    # (#2); it must now be a clean :ok.
    assert :ok = evaluate_events_and_complete!([event.("anomaly_clear", 30)])

    {:ok, still_resolved} = Alert.get_by_id(active_alert.id, actor: actor)
    assert still_resolved.status == :resolved

    recovered_after =
      rule.id
      |> StatefulAlertRuleHistory.list_by_rule(actor: actor)
      |> Page.unwrap!()
      |> Enum.count(&(&1.event_type == :recovered))

    # Idempotent: the terminal-alert clear records no new :recovered history.
    assert recovered_after == recovered_before
  end

  test "causal anomaly alerts can group by canonical metric tuple without series-key equality", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device_uid = "sr:snmp-target-device-#{unique}"
    metric_name = "ifHCOutOctets"
    if_index = 4
    alert_title = "SNMP anomaly tuple #{unique}"

    {:ok, _rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "snmp-anomaly-tuple-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => "anomaly",
              "anomaly.state" => ["anomaly_open", "open", "anomalous"]
            }
          },
          group_by: ["device_id", "anomaly.metric_name", "anomaly.if_index"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 300,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.health.anomaly_detection",
            "message" => "SNMP anomaly detected"
          },
          alert: %{"title" => alert_title, "severity_from" => "source"}
        },
        actor: actor
      )
      |> Ash.create()

    anomaly_series_key =
      Enum.join(
        [
          "v2",
          anomaly_key_component("partition", "net"),
          anomaly_key_component("identity", "192.168.10.1"),
          anomaly_key_component("metric", metric_name),
          anomaly_key_component("if_index", if_index)
        ],
        "|"
      )

    event = %{
      id: Ash.UUID.generate(),
      time: DateTime.utc_now(),
      severity_id: OCSF.severity_high(),
      severity: OCSF.severity_name(OCSF.severity_high()),
      message: "Anomaly open",
      log_name: "signals.analytics.predictions.#{anomaly_series_key}",
      log_provider: "anomaly_detection",
      device: %{"uid" => device_uid},
      unmapped: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "anomaly" => %{
          "state" => "anomaly_open",
          "series_key" => anomaly_series_key,
          "metric_class" => "snmp.interface",
          "metric_name" => metric_name,
          "if_index" => if_index
        }
      },
      metadata: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "service_radar" => %{"device_id" => device_uid}
      }
    }

    assert :ok = evaluate_events_and_complete!([event])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    # The engine stringifies every group value (Record.build_group/2 uses
    # to_string/1 so the group key and values stay consistent), so the integer
    # if_index is recorded as its string form.
    assert active_alert.metadata["incident_group_values"] == %{
             "anomaly.if_index" => to_string(if_index),
             "anomaly.metric_name" => metric_name,
             "device_id" => device_uid
           }
  end

  test "central seasonal normal state suppresses matching edge-spike anomaly alert", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device_uid = "sr:seasonal-suppressed-device-#{unique}"
    series_key = "sysmon:cpu:#{device_uid}:0"
    alert_title = "Seasonally disposed anomaly #{unique}"

    {:ok, _rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "seasonally-disposed-anomaly-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => ["anomaly", "anomaly_detection"],
              "anomaly.metric_class" => "sysmon.cpu",
              "anomaly.state" => ["anomaly_open", "open", "anomalous"]
            },
            "recovery" => %{
              "subject_prefix" => "signals.analytics.predictions",
              "attribute_equals" => %{
                "signal_type" => "prediction",
                "event_type" => ["anomaly", "anomaly_detection"],
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

    base_time = DateTime.truncate(DateTime.utc_now(), :microsecond)
    bucket_started_at = DateTime.shift(base_time, minute: -1)
    bucket_ended_at = DateTime.shift(base_time, hour: 1)
    dow = base_time |> DateTime.to_date() |> Date.day_of_week() |> rem(7)
    hod = base_time.hour

    assert :ok =
             SeasonalStateStore.persist_many(
               %Source{name: "cpu_seasonal"},
               [
                 %{
                   key: {series_key, dow, hod},
                   consecutive_anomalous: 0,
                   disposition: "normal",
                   status: "normal",
                   score: 0.2,
                   evaluated_at: base_time,
                   bucket_started_at: bucket_started_at,
                   bucket_ended_at: bucket_ended_at
                 }
               ]
             )

    event = fn verdict_source, offset ->
      %{
        id: Ash.UUID.generate(),
        time: DateTime.shift(base_time, second: offset),
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "Anomaly #{verdict_source}",
        log_name: "signals.analytics.predictions.#{series_key}",
        log_provider: "anomaly_detection",
        device: %{"uid" => device_uid},
        unmapped: %{
          "signal_type" => "prediction",
          "event_type" => "anomaly",
          "verdict_source" => verdict_source,
          "anomaly" => %{
            "state" => "anomaly_open",
            "series_key" => series_key,
            "metric_class" => "sysmon.cpu",
            "verdict_source" => verdict_source
          }
        },
        metadata: %{
          "signal_type" => "prediction",
          "event_type" => "anomaly",
          "service_radar" => %{"verdict_source" => verdict_source}
        }
      }
    end

    assert :ok = evaluate_events_and_complete!([event.("edge-spike", 10)])
    assert [] = active_alerts_by_title(actor, alert_title)

    assert :ok = evaluate_events_and_complete!([event.("central-seasonal", 20)])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    assert active_alert.metadata["incident_group_values"] == %{
             "anomaly.series_key" => series_key,
             "device" => device_uid
           }
  end

  test "unsupported seasonal metric classes pass through edge-spike anomaly alerts", %{
    actor: actor
  } do
    base_time = DateTime.truncate(DateTime.utc_now(), :microsecond)
    bucket_started_at = DateTime.shift(base_time, minute: -1)
    bucket_ended_at = DateTime.shift(base_time, hour: 1)
    dow = base_time |> DateTime.to_date() |> Date.day_of_week() |> rem(7)
    hod = base_time.hour

    for {metric_class, metric_name, severity_id, expected_severity} <- [
          {"snmp.interface", "ifInOctets", OCSF.severity_critical(), :critical},
          {"sysmon.process", "process.cpu_percent", OCSF.severity_high(), :critical}
        ] do
      unique = System.unique_integer([:positive])
      device_uid = "sr:edge-only-device-#{unique}"
      series_key = "#{metric_class}:#{device_uid}:#{metric_name}"
      alert_title = "Edge-only anomaly #{metric_class} #{unique}"

      # Even if a normal seasonal row exists for the same opaque series key, the
      # alert engine must not apply CPU/memory seasonal disposition to unsupported
      # classes. SNMP/interface and counter-like sysmon series remain edge-only.
      assert :ok =
               SeasonalStateStore.persist_many(
                 %Source{name: "cpu_seasonal"},
                 [
                   %{
                     key: {series_key, dow, hod},
                     consecutive_anomalous: 0,
                     disposition: "normal",
                     status: "normal",
                     score: 0.0,
                     evaluated_at: base_time,
                     bucket_started_at: bucket_started_at,
                     bucket_ended_at: bucket_ended_at
                   }
                 ]
               )

      {:ok, _rule} =
        StatefulAlertRule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "edge-only-anomaly-#{metric_class}-#{unique}",
            enabled: true,
            signal: :event,
            match: %{
              "subject_prefix" => "signals.analytics.predictions",
              "attribute_equals" => %{
                "signal_type" => "prediction",
                "event_type" => ["anomaly", "anomaly_detection"],
                "anomaly.metric_class" => metric_class,
                "anomaly.state" => ["anomaly_open", "open", "anomalous"]
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

      event = %{
        id: Ash.UUID.generate(),
        time: DateTime.shift(base_time, second: unique),
        severity_id: severity_id,
        severity: OCSF.severity_name(severity_id),
        message: "Anomaly edge-spike",
        log_name: "signals.analytics.predictions.#{series_key}",
        log_provider: "anomaly_detection",
        device: %{"uid" => device_uid},
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

      assert :ok = evaluate_events_and_complete!([event])
      assert [active_alert] = active_alerts_by_title(actor, alert_title)
      assert active_alert.severity == expected_severity

      assert active_alert.metadata["incident_group_values"] == %{
               "anomaly.series_key" => series_key,
               "device" => device_uid
             }
    end
  end

  test "resolve_stale_anomalies resolves an open alert whose series went silent", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device_uid = "sr:stale-anomaly-device-#{unique}"
    series_key = "sysmon:cpu:#{device_uid}:0"
    alert_title = "Stale anomaly #{unique}"
    rule_name = "stale-anomaly-rule-#{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: rule_name,
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => "anomaly",
              "anomaly.state" => ["anomaly_open", "open"]
            },
            "recovery" => %{
              "subject_prefix" => "signals.analytics.predictions",
              "attribute_equals" => %{
                "signal_type" => "prediction",
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
        time: DateTime.shift(base_time, second: offset),
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "Anomaly #{state}",
        log_name: "signals.analytics.predictions.#{series_key}",
        log_provider: "anomaly_detection",
        device: %{"uid" => device_uid},
        unmapped: %{
          "signal_type" => "prediction",
          "event_type" => "anomaly",
          "anomaly" => %{
            "state" => state,
            "series_key" => series_key,
            "metric_class" => "sysmon.cpu"
          }
        },
        metadata: %{"signal_type" => "prediction", "event_type" => "anomaly"}
      }
    end

    # Open the alert; the series' last matching record is at base_time + 10s.
    assert :ok = evaluate_events_and_complete!([event.("pending_anomaly", 0)])
    assert :ok = evaluate_events_and_complete!([event.("anomaly_open", 10)])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    # The series goes silent (no anomaly_clear ever arrives). A cutoff after its
    # last_seen_at marks the open snapshot stale, and the sweep resolves it.
    cutoff = DateTime.shift(base_time, hour: 1)
    now = DateTime.shift(base_time, hour: 1)
    assert {:ok, 1} = resolve_and_complete!(rule_name, cutoff, now)

    {:ok, resolved} = Alert.get_by_id(active_alert.id, actor: actor)
    assert resolved.status == :resolved
    assert [] = active_alerts_by_title(actor, alert_title)

    history =
      rule.id |> StatefulAlertRuleHistory.list_by_rule(actor: actor) |> Page.unwrap!()

    assert Enum.any?(history, &(&1.event_type == :recovered))

    # Idempotent: the alert_id was nulled, so a second sweep resolves nothing.
    assert {:ok, 0} = resolve_and_complete!(rule_name, cutoff, now)
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
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => "capacity_forecast",
              "capacity_forecast.status" => "projected"
            },
            "recovery" => %{
              "subject_prefix" => "signals.analytics.predictions",
              "attribute_equals" => %{
                "signal_type" => "prediction",
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
        time: DateTime.shift(base_time, second: offset),
        severity_id: OCSF.severity_critical(),
        severity: OCSF.severity_name(OCSF.severity_critical()),
        message: "Capacity forecast #{status}",
        log_name: "signals.analytics.predictions.capacity.#{unique}",
        log_provider: "capacity_forecasting",
        device: %{"uid" => device_uid},
        unmapped: %{
          "signal_type" => "prediction",
          "event_type" => "capacity_forecast",
          "capacity_forecast" => %{
            "status" => status,
            "resource_key" => resource_key,
            "resource_type" => "disk",
            "metric_name" => "usage_percent"
          }
        },
        metadata: %{"signal_type" => "prediction", "event_type" => "capacity_forecast"}
      }
    end

    assert :ok = evaluate_events_and_complete!([event.("inactive", 0)])
    assert [] = active_alerts_by_title(actor, alert_title)

    assert :ok = evaluate_events_and_complete!([event.("projected", 10)])
    assert [active_alert] = active_alerts_by_title(actor, alert_title)

    assert active_alert.severity == :critical

    assert active_alert.metadata["incident_group_values"] == %{
             "capacity_forecast.resource_key" => resource_key,
             "device" => device_uid
           }

    assert :ok = evaluate_events_and_complete!([event.("projected", 20)])
    assert [same_alert] = active_alerts_by_title(actor, alert_title)
    assert same_alert.id == active_alert.id
    assert same_alert.metadata["incident_occurrence_count"] == 2

    assert :ok = evaluate_events_and_complete!([event.("inactive", 30)])
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

    assert :ok = evaluate_events_and_complete!([event.(base_time)])

    assert :ok =
             evaluate_events_and_complete!([event.(DateTime.shift(base_time, second: 30))])

    assert :ok =
             evaluate_events_and_complete!([event.(DateTime.shift(base_time, second: 90))])

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

    rollover_time = DateTime.shift(base_time, minute: 7)
    assert :ok = evaluate_events_and_complete!([event.(rollover_time)])

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

  test "admits only matching rules and commits one alert for each independent rule",
       %{actor: actor} do
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

    %{rows: admitted} =
      Repo.query!(
        "SELECT rule_id::text, payload->'unmapped'->'log_attributes'->>'fanout_index' FROM platform.alert_evaluation_work WHERE rule_id::text = ANY($1::text[])",
        [Enum.map(rules, fn {_index, _title, rule} -> rule.id end)]
      )

    assert MapSet.new(admitted) ==
             MapSet.new(rules, fn {index, _title, rule} -> [rule.id, to_string(index)] end)

    for {_index, title, _rule} <- rules, do: assert(active_alerts_by_title(actor, title) == [])
    TestSupport.complete_alert_effects!()

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

  test "routing evaluates raw-writer rule changes and replay truncates from one snapshot", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])

    # The match discriminator stays fixed per family while every occurrence
    # carries a fresh grouping value: a stale match after an update or delete
    # would fire a new group (and a new persisted alert) instead of being
    # hidden by the rule's cooldown on a reused group.
    raw_event = fn family, occurrence ->
      %{
        id: Ash.UUID.generate(),
        time: DateTime.utc_now(),
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "raw writer event",
        log_name: "raw_writer",
        log_provider: "raw_writer",
        unmapped: %{
          "log_attributes" => %{
            "routing_family" => family,
            "routing_occurrence" => occurrence
          }
        }
      }
    end

    count_alerts = fn title ->
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.count(&(&1.title == title))
    end

    # A prior batch must not hide a subsequent raw write behind a rule cache.
    assert :ok =
             evaluate_events_and_complete!([
               raw_event.("warm-#{unique}", "warm-#{unique}-1")
             ])

    title = "Shard raw writer #{unique}"
    raw_id = Ash.UUID.generate()

    Repo.query!(
      "INSERT INTO platform.stateful_alert_rules (id, name, signal, match, group_by, threshold, window_seconds, bucket_seconds, cooldown_seconds, renotify_seconds, event, alert) VALUES ($1::uuid, $2, 'event', $3::jsonb, '{routing_occurrence}', 1, 300, 60, 60, 3600, $4::jsonb, $5::jsonb)",
      [
        Ecto.UUID.dump!(raw_id),
        "shard-fanout-#{unique}-raw",
        %{"attribute_equals" => %{"routing_family" => "#{unique}"}},
        %{
          "log_name" => "alert.test.shard_raw_writer",
          "message" => "Raw writer finding"
        },
        %{"title" => title, "severity" => "warning"}
      ]
    )

    # The next batch routes from the same snapshot it evaluates: the raw rule
    # fires a persisted alert, while an unrelated family still fires nothing.
    assert :ok = evaluate_events_and_complete!([raw_event.("#{unique}", "#{unique}-1")])
    assert count_alerts.(title) == 1

    assert :ok =
             evaluate_events_and_complete!([
               raw_event.("other-#{unique}", "other-#{unique}-1")
             ])

    assert count_alerts.(title) == 1

    # A raw update is visible to the next batch: the old family stops matching
    # and the new family starts matching, each with persisted outcomes. Fresh
    # occurrences prove the negative: a stale rule would fire a second alert
    # in a new group instead of being suppressed by cooldown.
    Repo.query!(
      "UPDATE platform.stateful_alert_rules SET match = $2::jsonb WHERE id = $1::uuid",
      [
        Ecto.UUID.dump!(raw_id),
        %{"attribute_equals" => %{"routing_family" => "updated-#{unique}"}}
      ]
    )

    assert :ok = evaluate_events_and_complete!([raw_event.("#{unique}", "#{unique}-2")])
    assert count_alerts.(title) == 1

    updated_title = "#{title} updated"

    Repo.query!(
      "UPDATE platform.stateful_alert_rules SET alert = $2::jsonb WHERE id = $1::uuid",
      [
        Ecto.UUID.dump!(raw_id),
        %{"title" => updated_title, "severity" => "warning"}
      ]
    )

    assert :ok =
             evaluate_events_and_complete!([
               raw_event.("updated-#{unique}", "updated-#{unique}-1")
             ])

    assert count_alerts.(updated_title) == 1

    # A raw delete is visible to the next batch: nothing more fires, even with
    # a fresh occurrence that would escape cooldown under a stale rule.
    Repo.query!("DELETE FROM platform.stateful_alert_rules WHERE id = $1::uuid", [
      Ecto.UUID.dump!(raw_id)
    ])

    assert :ok =
             evaluate_events_and_complete!([
               raw_event.("updated-#{unique}", "updated-#{unique}-2")
             ])

    assert count_alerts.(updated_title) == 1

    ServiceRadar.Observability.ApiEvent.ClearForReplay.clear_records!([])

    assert :ok =
             evaluate_events_and_complete!([raw_event.("updated-#{unique}", "after-truncate")])

    assert Repo.query!("SELECT count(*) FROM platform.alert_evaluation_work").rows == [[0]]
  end

  test "accepted input evaluates its captured revision after a later rule edit", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])

    title_v1 = "Snapshot coherence #{unique} v1"
    title_v2 = "Snapshot coherence #{unique} v2"
    family = "#{unique}"
    occurrence = "#{unique}-coherent-1"
    rule_name = "shard-fanout-#{unique}-coherent"
    raw_id = Ash.UUID.generate()

    {:ok, _rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: rule_name,
          enabled: true,
          signal: :event,
          match: %{"attribute_equals" => %{"routing_family" => family}},
          group_by: ["routing_occurrence"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 60,
          renotify_seconds: 3600,
          event: %{"log_name" => "alert.test.shard_coherent", "message" => "Coherent finding"},
          alert: %{"title" => title_v1, "severity" => "warning"}
        },
        actor: actor
      )
      |> Ash.Changeset.force_change_attribute(:id, raw_id)
      |> Ash.create()

    event = %{
      id: Ash.UUID.generate(),
      time: DateTime.utc_now(),
      severity_id: OCSF.severity_high(),
      severity: OCSF.severity_name(OCSF.severity_high()),
      message: "coherent event",
      log_name: "coherent",
      log_provider: "coherent",
      unmapped: %{
        "log_attributes" => %{"routing_family" => family, "routing_occurrence" => occurrence}
      }
    }

    count_alerts = fn title ->
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.count(&(&1.title == title))
    end

    assert :ok = StatefulAlertEngine.evaluate_events([event])
    assert count_alerts.(title_v1) == 0
    assert count_alerts.(title_v2) == 0

    Repo.query!(
      "UPDATE platform.stateful_alert_rules SET alert = $2::jsonb WHERE id = $1::uuid",
      [Ecto.UUID.dump!(raw_id), %{"title" => title_v2, "severity" => "warning"}]
    )

    TestSupport.complete_alert_effects!()

    # Effects belong to the revision committed with acceptance, rather than
    # whichever revision happens to be current when a worker runs.
    assert count_alerts.(title_v1) == 1
    assert count_alerts.(title_v2) == 0
  end

  defp active_alerts_by_title(actor, title) do
    Alert
    |> Ash.Query.for_read(:active, %{}, actor: actor)
    |> Ash.read!()
    |> Page.unwrap!()
    |> Enum.filter(fn alert -> alert.title == title end)
  end

  # Public admission is asynchronous. Effects are read only after the real
  # worker has committed receipts and the real outbox has delivered events.
  defp evaluate_events_and_complete!(events) do
    result = StatefulAlertEngine.evaluate_events(events)
    if result == :ok, do: TestSupport.complete_alert_effects!()
    result
  end

  defp evaluate_metrics_and_complete!(metrics) do
    result = StatefulAlertEngine.evaluate_metrics(metrics)
    if result == :ok, do: TestSupport.complete_alert_effects!()
    result
  end

  defp resolve_and_complete!(rule_name, cutoff, now) do
    TestSupport.complete_alert_operation!(fn ->
      StatefulAlertEngine.resolve_stale_anomalies(rule_name, cutoff, now)
    end)
  end

  defp run_liveness_and_complete!(opts) do
    TestSupport.complete_alert_operation!(fn -> AnomalyAlertLivenessCheck.run(opts) end)
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

  defp persisted_anomaly_event_for_device?(device_uid) do
    case Repo.query(
           "SELECT 1 FROM platform.ocsf_events WHERE class_uid = 2004 AND device->>'uid' = $1 LIMIT 1",
           [device_uid]
         ) do
      {:ok, %{num_rows: 1}} -> true
      _ -> false
    end
  end

  defp anomaly_key_component(name, value) do
    "#{name}=#{value |> to_string() |> Base.encode16(case: :lower)}"
  end
end
