// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource};
use serviceradar_anomaly_core::ReasonVerdict;

use super::support::entry;
use crate::engine::AnomalyTransition;
use crate::identity::{safe_component, series_key_for};
use crate::verdict::verdict_record;

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
    );
    let second = verdict_record(
        &resource,
        &metric,
        &point,
        &series_key,
        &verdict,
        AnomalyTransition::Open,
    );
    let event: serde_json::Value = serde_json::from_slice(&first.payload).unwrap();
    let expected_event_id = format!("anomaly:{series_key}:{sample_time}:anomaly_open");

    assert_eq!(first.event_id, expected_event_id);
    assert_eq!(second.event_id, expected_event_id);
    assert_eq!(first.event_time_unix_nano, sample_time as i64);
    assert_eq!(first.observed_time_unix_nano, sample_time as i64);
    assert_eq!(event["event_id"], expected_event_id);
    assert_eq!(event["id"], expected_event_id);
    assert_eq!(event["time"], (sample_time / 1_000_000) as i64);
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
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
    let expected_event_id = format!("anomaly:{series_key}:{point_time}:anomaly_open");

    assert_eq!(record.event_id, expected_event_id);
    assert_eq!(record.event_time_unix_nano, point_time as i64);
    assert_eq!(record.observed_time_unix_nano, point_time as i64);
    assert_eq!(event["time"], (point_time / 1_000_000) as i64);
    assert_eq!(event["anomaly"]["observed_at_unix_nano"], point_time);
}
