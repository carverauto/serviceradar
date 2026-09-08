// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource};
use serviceradar_anomaly_core::{ReasonVerdict, SignalVerdict};

use super::support::entry;
use crate::config::ADDON_VERSION;
use crate::engine::{AnomalyEpisode, AnomalyTransition, CusumDirection, CusumDrift};
use crate::identity::{safe_component, series_key_for};
use crate::verdict::{anomaly_signal_schema_ref, cusum_drift_record, verdict_record};

fn manifest_root_value<'a>(manifest: &'a str, key: &str) -> &'a str {
    let prefix = format!("{key}:");

    manifest
        .lines()
        .find_map(|line| {
            line.strip_prefix(&prefix)
                .map(|value| value.trim().trim_matches('"'))
        })
        .unwrap_or_else(|| panic!("manifest is missing root key {key}"))
}

fn manifest_signal_value<'a>(manifest: &'a str, schema_id: &str, key: &str) -> &'a str {
    let schema_prefix = format!("  - id: {schema_id}");
    let value_prefix = format!("{key}:");
    let mut selected = false;

    for line in manifest.lines() {
        if line.starts_with("  - id:") {
            selected = line == schema_prefix;
            continue;
        }

        if selected {
            if !line.starts_with("    ") {
                break;
            }

            if let Some(value) = line.trim().strip_prefix(&value_prefix) {
                return value.trim().trim_matches('"');
            }
        }
    }

    panic!("manifest schema {schema_id} is missing key {key}")
}

#[test]
fn emitted_detection_ref_matches_the_shipped_manifest_and_contract() {
    let manifest = include_str!("../../../../addons/anomaly-addon/addon.yaml");
    let contract: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../addons/anomaly-addon/display/detection_finding.display.json"
    ))
    .expect("detection display contract json");
    let signal_ref = anomaly_signal_schema_ref();

    assert_eq!(signal_ref.producer_id, manifest_root_value(manifest, "id"));
    assert_eq!(
        signal_ref.producer_version,
        manifest_root_value(manifest, "version")
    );
    assert_eq!(
        signal_ref.schema_version,
        manifest_signal_value(manifest, &signal_ref.schema_id, "version")
    );
    assert_eq!(
        signal_ref.display_contract,
        manifest_signal_value(manifest, &signal_ref.schema_id, "display_contract")
    );
    assert_eq!(
        signal_ref.display_contract_id,
        manifest_signal_value(manifest, &signal_ref.schema_id, "display_contract_id")
    );
    assert_eq!(
        signal_ref.display_contract_version,
        manifest_signal_value(manifest, &signal_ref.schema_id, "display_contract_version")
    );
    assert_eq!(
        contract["schema_id"].as_str(),
        Some(signal_ref.schema_id.as_str())
    );
    assert_eq!(
        contract["schema_version"].as_str(),
        Some(signal_ref.schema_version.as_str())
    );
    assert_eq!(
        contract["id"].as_str(),
        Some(signal_ref.display_contract_id.as_str())
    );
    assert_eq!(
        contract["version"].as_str(),
        Some(signal_ref.display_contract_version.as_str())
    );
}

#[test]
fn snmp_remote_target_drives_edge_verdict_identity() {
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        host_ip: "10.0.0.10".to_string(),
        target_device_ip: "10.0.0.20".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifHCInOctets".to_string(),
        metric_type: "snmp".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 1234.0,
        observed_at_unix_nano: 1_812_456_000_000_000_000,
        if_index: 7,
        interface_uid: "ifindex:7".to_string(),
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 1,
        score: 4.2,
        reason: "test breach".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 1234.0,
        observed_at_unix_nano: Some(1_812_456_000_000_000_000),
        signals: Vec::new(),
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(
        series_key,
        [
            "v2".to_string(),
            safe_component("partition", "demo"),
            safe_component("identity", "10.0.0.20"),
            safe_component("metric", "ifHCInOctets"),
            safe_component("interface_uid", "ifindex:7"),
            safe_component("if_index", "7"),
        ]
        .join("|")
    );
    assert_eq!(event["device_uid"], "10.0.0.20");
    assert_eq!(event["device_id"], "10.0.0.20");
    assert_eq!(event["target_device_ip"], "10.0.0.20");
    assert_eq!(event["anomaly"]["target_device_ip"], "10.0.0.20");
    assert_eq!(event["source_identity"]["target_device_ip"], "10.0.0.20");
    assert_eq!(event["source_identity"]["agent_id"], "agent-ns03");
}

#[test]
fn snmp_tagged_target_drives_edge_verdict_identity_without_resource_target() {
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        host_ip: "10.0.0.10".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifHCInOctets".to_string(),
        metric_type: "snmp".to_string(),
        tags: vec![entry("target", "router-a"), entry("host", "10.0.0.20")],
        ..Default::default()
    };
    let point = MetricPoint {
        value: 1234.0,
        observed_at_unix_nano: 1_812_456_000_000_000_000,
        if_index: 7,
        interface_uid: "ifindex:7".to_string(),
        attributes: vec![entry("target", "router-a"), entry("host", "10.0.0.20")],
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 1,
        score: 4.2,
        reason: "test breach".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 1234.0,
        observed_at_unix_nano: Some(1_812_456_000_000_000_000),
        signals: Vec::new(),
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(
        series_key,
        [
            "v2".to_string(),
            safe_component("partition", "demo"),
            safe_component("identity", "10.0.0.20"),
            safe_component("metric", "ifHCInOctets"),
            safe_component("interface_uid", "ifindex:7"),
            safe_component("if_index", "7"),
        ]
        .join("|")
    );
    assert_eq!(event["device_uid"], "10.0.0.20");
    assert_eq!(event["device_id"], "10.0.0.20");
    assert_eq!(event["target_device_ip"], "10.0.0.20");
    assert_eq!(event["anomaly"]["target_device_ip"], "10.0.0.20");
    assert_eq!(event["source_identity"]["target_device_ip"], "10.0.0.20");
    assert_eq!(event["source_identity"]["agent_id"], "agent-ns03");
}

#[test]
fn edge_verdict_identity_uses_producer_sample_time() {
    let sample_time = 1_812_456_123_456_789_000_u64;
    let point_time = sample_time - 42_000_000;
    let resource = MetricResource {
        agent_id: "agent-a".to_string(),
        host_id: "host-a".to_string(),
        device_id: "device-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 99.0,
        observed_at_unix_nano: point_time,
        series_identity_hint: "device-a|cpu0".to_string(),
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 5,
        score: 6.0,
        reason: "sample-time breach".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 99.0,
        observed_at_unix_nano: Some(sample_time),
        signals: Vec::new(),
    };

    let first = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let second = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let event: serde_json::Value = serde_json::from_slice(&first.payload).unwrap();
    let episode_uid = event["episode_uid"].as_str().unwrap();
    let expected_event_id = format!("anomaly:{episode_uid}:open:severity-3");

    assert_eq!(first.event_id, expected_event_id);
    assert_eq!(second.event_id, expected_event_id);
    assert_eq!(first.event_time_unix_nano, sample_time as i64);
    assert_eq!(first.observed_time_unix_nano, sample_time as i64);
    assert_eq!(event["event_id"], expected_event_id);
    assert_eq!(event["id"], expected_event_id);
    assert_eq!(event["time"], (sample_time / 1_000_000) as i64);
    assert_eq!(event["producer_version"], ADDON_VERSION);
    assert_eq!(event["transition"], "open");
    assert_eq!(event["anomaly"]["producer_version"], ADDON_VERSION);
    assert_eq!(event["anomaly"]["episode_uid"], episode_uid);
    assert_eq!(event["anomaly"]["transition"], "open");
    assert_eq!(
        event["anomaly"]["episode_started_at_unix_nano"],
        sample_time
    );
    assert_eq!(event["anomaly"]["observed_at_unix_nano"], sample_time);
}

#[test]
fn edge_verdict_identity_falls_back_to_point_time_without_sample_time() {
    let point_time = 1_812_456_123_456_789_000_u64;
    let resource = MetricResource {
        agent_id: "agent-a".to_string(),
        host_id: "host-a".to_string(),
        device_id: "device-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 99.0,
        observed_at_unix_nano: point_time,
        series_identity_hint: "device-a|cpu0".to_string(),
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 5,
        score: 6.0,
        reason: "point-time breach".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 99.0,
        observed_at_unix_nano: None,
        signals: Vec::new(),
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
    let episode_uid = event["episode_uid"].as_str().unwrap();
    let expected_event_id = format!("anomaly:{episode_uid}:open:severity-3");

    assert_eq!(record.event_id, expected_event_id);
    assert_eq!(record.event_time_unix_nano, point_time as i64);
    assert_eq!(record.observed_time_unix_nano, point_time as i64);
    assert_eq!(event["event_id"], expected_event_id);
    assert_eq!(event["id"], expected_event_id);
    assert_eq!(event["time"], (point_time / 1_000_000) as i64);
    assert_eq!(event["transition"], "open");
    assert_eq!(event["anomaly"]["episode_uid"], episode_uid);
    assert_eq!(event["anomaly"]["transition"], "open");
    assert_eq!(event["anomaly"]["episode_started_at_unix_nano"], point_time);
    assert_eq!(event["anomaly"]["observed_at_unix_nano"], point_time);
}

#[test]
fn edge_verdict_includes_episode_window_and_peak_when_present() {
    let resource = MetricResource {
        agent_id: "agent-a".to_string(),
        host_id: "host-a".to_string(),
        device_id: "device-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 88.0,
        observed_at_unix_nano: 1_812_456_040_000_000_000,
        series_identity_hint: "device-a|cpu0".to_string(),
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 5,
        score: 6.0,
        reason: "confirmed".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 88.0,
        observed_at_unix_nano: Some(point.observed_at_unix_nano),
        signals: Vec::new(),
    };
    let episode = AnomalyEpisode {
        started_at_unix_nano: 1_812_456_010_000_000_000,
        ended_at_unix_nano: 1_812_456_040_000_000_000,
        peak_value: 97.7,
        peak_at_unix_nano: 1_812_456_022_000_000_000,
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        Some(episode),
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
    let episode_uid = event["episode_uid"].as_str().unwrap();

    assert_eq!(
        record.event_id,
        format!("anomaly:{episode_uid}:open:severity-3")
    );
    assert_eq!(event["producer_version"], ADDON_VERSION);
    assert_eq!(event["transition"], "open");
    assert_eq!(event["anomaly"]["producer_version"], ADDON_VERSION);
    assert_eq!(event["anomaly"]["episode_uid"], episode_uid);
    assert_eq!(event["anomaly"]["transition"], "open");
    assert_eq!(
        event["anomaly"]["episode_started_at_unix_nano"],
        episode.started_at_unix_nano
    );
    assert_eq!(
        event["anomaly"]["episode_ended_at_unix_nano"],
        episode.ended_at_unix_nano
    );
    assert_eq!(event["anomaly"]["episode_peak_value"], episode.peak_value);
    assert_eq!(
        event["anomaly"]["episode_peak_at_unix_nano"],
        episode.peak_at_unix_nano
    );
}

#[test]
fn edge_verdict_includes_signal_evidence_for_operator_explanation() {
    let resource = MetricResource {
        agent_id: "agent-a".to_string(),
        host_id: "host-a".to_string(),
        device_id: "device-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 92.0,
        observed_at_unix_nano: 1_812_456_040_000_000_000,
        attributes: vec![entry("core_id", "4")],
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 8,
        score: 4.6,
        reason: "breach confirmed after 8/5 consecutive anomalous slots".to_string(),
        baseline_count: 300,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 92.0,
        observed_at_unix_nano: Some(point.observed_at_unix_nano),
        signals: vec![SignalVerdict {
            name: "rolling_zscore".to_string(),
            enabled: true,
            ready: true,
            breached: true,
            score: 4.6,
            threshold: 3.0,
            sample_count: 300,
            mean: Some(11.2),
            stddev: Some(17.6),
            reason: "rolling_zscore breach".to_string(),
        }],
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
    let signal = &event["anomaly"]["signals"][0];

    assert_eq!(event["anomaly"]["consecutive_anomalous"], 8);
    assert_eq!(signal["name"], "rolling_zscore");
    assert_eq!(signal["enabled"], true);
    assert_eq!(signal["ready"], true);
    assert_eq!(signal["breached"], true);
    assert_eq!(signal["score"], 4.6);
    assert_eq!(signal["threshold"], 3.0);
    assert_eq!(signal["sample_count"], 300);
    assert_eq!(signal["mean"], 11.2);
    assert_eq!(signal["stddev"], 17.6);
    assert_eq!(signal["reason"], "rolling_zscore breach");
}

#[test]
fn severity_id_clamps_unconfirmed_breadcrumb_to_low() {
    use crate::verdict::severity_id_from_score;

    // Confirmed base bands cap at High; Critical requires class impact + duration.
    assert_eq!(severity_id_from_score(8.5, true), 4);
    assert_eq!(severity_id_from_score(4.82, true), 3);
    assert_eq!(severity_id_from_score(2.5, true), 2);
    assert_eq!(severity_id_from_score(1.0, true), 2);

    // Unconfirmed (pending breadcrumb): never escalates past Low, regardless of
    // how large the raw score is.
    assert_eq!(severity_id_from_score(6.5, false), 2);
    assert_eq!(severity_id_from_score(4.82, false), 2);
    assert_eq!(severity_id_from_score(2.5, false), 2);
    assert_eq!(severity_id_from_score(1.0, false), 2);
}

#[test]
fn edge_drift_record_caps_score_and_severity() {
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifHCInOctets".to_string(),
        metric_type: "snmp".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 12_345.0,
        observed_at_unix_nano: 1_812_456_040_000_000_000,
        if_index: 7,
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "normal".to_string(),
        anomalous: false,
        breached: false,
        include_in_baseline: true,
        next_consecutive_anomalous: 0,
        score: 0.5,
        reason: "normal".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 12_345.0,
        observed_at_unix_nano: Some(1_812_456_040_000_000_000),
        signals: Vec::new(),
    };

    let record = cusum_drift_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        CusumDrift {
            pos: 1.0e12,
            neg: 0.0,
            direction: CusumDirection::Up,
            shift_estimate: 1.0e12,
            transition: AnomalyTransition::Open,
            episode: None,
            clear_reason: None,
            update_reason: None,
            reopen_count: 0,
        },
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(event["verdict_source"], "edge-drift");
    assert_eq!(event["severity_id"], 3);
    assert_eq!(event["producer_version"], ADDON_VERSION);
    assert_eq!(event["transition"], "open");
    assert_eq!(event["anomaly"]["producer_version"], ADDON_VERSION);
    assert_eq!(event["anomaly"]["transition"], "open");
    assert_eq!(
        record.event_id,
        format!(
            "anomaly:{}:open:severity-3",
            event["episode_uid"].as_str().unwrap()
        )
    );
    assert_eq!(event["anomaly"]["episode_uid"], event["episode_uid"]);
    assert_eq!(event["anomaly"]["score"], 50.0);
    assert_eq!(event["anomaly"]["cusum_pos"], 1.0e12);
}

#[test]
fn edge_drift_update_escalates_to_high_only_after_delay() {
    let ts = 1_812_456_040_000_000_000;
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifHCInOctets".to_string(),
        metric_type: "snmp".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 12_345.0,
        observed_at_unix_nano: ts,
        if_index: 7,
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "normal".to_string(),
        anomalous: false,
        breached: false,
        include_in_baseline: true,
        next_consecutive_anomalous: 0,
        score: 0.5,
        reason: "normal".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 12_345.0,
        observed_at_unix_nano: Some(ts),
        signals: Vec::new(),
    };
    let episode = AnomalyEpisode {
        started_at_unix_nano: ts - 3_601 * 1_000_000_000,
        ended_at_unix_nano: ts,
        peak_value: 12_345.0,
        peak_at_unix_nano: ts,
    };

    let record = cusum_drift_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        CusumDrift {
            pos: 12.0,
            neg: 0.0,
            direction: CusumDirection::Up,
            shift_estimate: 12.0,
            transition: AnomalyTransition::Update,
            episode: Some(episode),
            clear_reason: None,
            update_reason: None,
            reopen_count: 0,
        },
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(event["severity_id"], 4);
    assert_eq!(event["transition"], "update");
}

#[test]
fn edge_spike_record_caps_stored_score() {
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 99.0,
        observed_at_unix_nano: 1_812_456_040_000_000_000,
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 5,
        score: 1.0e12,
        reason: "breach confirmed".to_string(),
        baseline_count: 30,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 99.0,
        observed_at_unix_nano: Some(1_812_456_040_000_000_000),
        signals: Vec::new(),
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(event["severity_id"], 4);
    assert_eq!(event["anomaly"]["score"], 50.0);
}

#[test]
fn synthetic_severity_calibration_corpus_bounds_critical_share_and_scores() {
    let ts = 1_812_456_040_000_000_000;
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let long_episode = |peak_value| AnomalyEpisode {
        started_at_unix_nano: ts - 900 * 1_000_000_000,
        ended_at_unix_nano: ts,
        peak_value,
        peak_at_unix_nano: ts,
    };
    let verdict = |sample_value, mean| ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 20,
        score: 1.0e12,
        reason: "synthetic corpus breach".to_string(),
        baseline_count: 300,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value,
        observed_at_unix_nano: Some(ts),
        signals: vec![SignalVerdict {
            name: "rolling_zscore".to_string(),
            enabled: true,
            ready: true,
            breached: true,
            score: 1.0e12,
            threshold: 3.0,
            sample_count: 300,
            mean: Some(mean),
            stddev: Some(0.25),
            reason: "synthetic corpus breach".to_string(),
        }],
    };
    let event_for = |metric: Metric, point: MetricPoint, verdict: ReasonVerdict| {
        let series_key = series_key_for(&resource, &metric, &point);
        let record = verdict_record(
            &resource,
            &metric,
            &point,
            &series_key,
            &verdict,
            AnomalyTransition::Open,
            Some(long_episode(verdict.sample_value)),
        );
        serde_json::from_slice::<serde_json::Value>(&record.payload).expect("event json")
    };

    let mut events = Vec::new();
    for index in 0..200 {
        let event = match index % 4 {
            0 => event_for(
                Metric {
                    name: "cpu.usage_percent".to_string(),
                    metric_type: "sysmon.cpu".to_string(),
                    ..Default::default()
                },
                MetricPoint {
                    value: 99.0,
                    observed_at_unix_nano: ts + index,
                    attributes: vec![entry("core_id", &format!("{}", index % 32))],
                    ..Default::default()
                },
                verdict(99.0, 20.0),
            ),
            1 => event_for(
                Metric {
                    name: "memory.used_percent".to_string(),
                    metric_type: "sysmon.memory".to_string(),
                    ..Default::default()
                },
                MetricPoint {
                    value: 82.0,
                    observed_at_unix_nano: ts + index,
                    ..Default::default()
                },
                verdict(82.0, 79.0),
            ),
            2 => event_for(
                Metric {
                    name: "ifHCInOctets".to_string(),
                    metric_type: "snmp".to_string(),
                    ..Default::default()
                },
                MetricPoint {
                    value: 2_000.0,
                    observed_at_unix_nano: ts + index,
                    if_index: index as i32,
                    ..Default::default()
                },
                verdict(2_000.0, 1_000.0),
            ),
            _ => event_for(
                Metric {
                    name: "disk.used_percent".to_string(),
                    metric_type: "sysmon.disk".to_string(),
                    ..Default::default()
                },
                MetricPoint {
                    value: 97.0,
                    observed_at_unix_nano: ts + index,
                    ..Default::default()
                },
                verdict(97.0, 40.0),
            ),
        };
        events.push(event);
    }

    events.push(event_for(
        Metric {
            name: "memory.used_percent".to_string(),
            metric_type: "sysmon.memory".to_string(),
            ..Default::default()
        },
        MetricPoint {
            value: 92.0,
            observed_at_unix_nano: ts + 1_000,
            ..Default::default()
        },
        verdict(92.0, 60.0),
    ));

    let critical_count = events
        .iter()
        .filter(|event| event["severity_id"] == 5)
        .count();
    let critical_share = critical_count as f64 / events.len() as f64;
    assert!(
        critical_share < 0.01,
        "synthetic corpus Critical share must stay below 1%, got {critical_count}/{}",
        events.len()
    );
    assert!(
        events.iter().all(|event| event["anomaly"]["score"]
            .as_f64()
            .is_some_and(|score| score <= 50.0)),
        "stored anomaly scores must stay bounded at 50"
    );
}

#[test]
fn memory_saturation_requires_duration_before_critical() {
    let ts = 1_812_456_040_000_000_000;
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "memory.used_percent".to_string(),
        metric_type: "sysmon.memory".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 92.0,
        observed_at_unix_nano: ts,
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 20,
        score: 12.0,
        reason: "breach confirmed".to_string(),
        baseline_count: 300,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 92.0,
        observed_at_unix_nano: Some(ts),
        signals: vec![SignalVerdict {
            name: "rolling_zscore".to_string(),
            enabled: true,
            ready: true,
            breached: true,
            score: 12.0,
            threshold: 3.0,
            sample_count: 300,
            mean: Some(60.0),
            stddev: Some(2.0),
            reason: "rolling_zscore breach".to_string(),
        }],
    };
    let episode = AnomalyEpisode {
        started_at_unix_nano: ts - 601 * 1_000_000_000,
        ended_at_unix_nano: ts,
        peak_value: 92.0,
        peak_at_unix_nano: ts,
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        Some(episode),
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(event["severity_id"], 5);
}

#[test]
fn per_core_cpu_is_high_capped_even_when_saturated_long_enough() {
    let ts = 1_812_456_040_000_000_000;
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 99.0,
        observed_at_unix_nano: ts,
        attributes: vec![entry("core_id", "4")],
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 20,
        score: 12.0,
        reason: "breach confirmed".to_string(),
        baseline_count: 300,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 99.0,
        observed_at_unix_nano: Some(ts),
        signals: vec![SignalVerdict {
            name: "rolling_zscore".to_string(),
            enabled: true,
            ready: true,
            breached: true,
            score: 12.0,
            threshold: 3.0,
            sample_count: 300,
            mean: Some(20.0),
            stddev: Some(2.0),
            reason: "rolling_zscore breach".to_string(),
        }],
    };
    let episode = AnomalyEpisode {
        started_at_unix_nano: ts - 900 * 1_000_000_000,
        ended_at_unix_nano: ts,
        peak_value: 99.0,
        peak_at_unix_nano: ts,
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        Some(episode),
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(event["severity_id"], 4);
}

#[test]
fn percent_gauge_practical_significance_gate_caps_low() {
    let ts = 1_812_456_040_000_000_000;
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "memory.used_percent".to_string(),
        metric_type: "sysmon.memory".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 82.0,
        observed_at_unix_nano: ts,
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "anomalous".to_string(),
        anomalous: true,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 20,
        score: 12.0,
        reason: "breach confirmed".to_string(),
        baseline_count: 300,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 82.0,
        observed_at_unix_nano: Some(ts),
        signals: vec![SignalVerdict {
            name: "rolling_zscore".to_string(),
            enabled: true,
            ready: true,
            breached: true,
            score: 12.0,
            threshold: 3.0,
            sample_count: 300,
            mean: Some(79.0),
            stddev: Some(0.25),
            reason: "rolling_zscore breach".to_string(),
        }],
    };
    let episode = AnomalyEpisode {
        started_at_unix_nano: ts - 900 * 1_000_000_000,
        ended_at_unix_nano: ts,
        peak_value: 82.0,
        peak_at_unix_nano: ts,
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        Some(episode),
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(event["severity_id"], 2);
}

#[test]
fn pending_verdict_record_clamps_severity_even_when_surfaced() {
    // Simulate a (stale) producer emitting a still-pending breadcrumb as if it
    // were an open transition: the high z-score must not raise a High-severity
    // event because the anomaly is not yet confirmed.
    let resource = MetricResource {
        agent_id: "agent-ns03".to_string(),
        host_id: "ns03".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "cpu.usage_percent".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 92.0,
        observed_at_unix_nano: 1_812_456_040_000_000_000,
        ..Default::default()
    };
    let series_key = series_key_for(&resource, &metric, &point);
    let verdict = ReasonVerdict {
        state: "pending_anomaly".to_string(),
        anomalous: false,
        breached: true,
        include_in_baseline: false,
        next_consecutive_anomalous: 1,
        score: 4.82,
        reason: "breach pending confirmation at 1/5 consecutive anomalous slots".to_string(),
        baseline_count: 300,
        next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
        next_window_tail: Vec::new(),
        sample_value: 92.0,
        observed_at_unix_nano: Some(point.observed_at_unix_nano),
        signals: Vec::new(),
    };

    let record = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
        None,
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

    assert_eq!(event["anomaly"]["detector_state"], "pending_anomaly");
    assert_eq!(event["severity_id"], 2);
}
