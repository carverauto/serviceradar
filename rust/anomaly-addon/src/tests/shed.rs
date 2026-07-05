// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::metric_pb::MetricResource;

use crate::config::OCSF_CLASS_EVENT_LOG_ACTIVITY;
use crate::shed::{
    EmissionShedReport, EmissionShedSeries, ShedReport, emission_shed_record, shed_record,
};

#[test]
fn shed_record_is_operational_ocsf_event_not_an_anomaly() {
    let resource = MetricResource {
        agent_id: "agent-a".to_string(),
        host_id: "host-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let record = shed_record(
        &resource,
        42,
        ShedReport {
            dropped_delta: 3,
            dropped_total: 10,
            tracked_series: 1,
            tracked_counters: 2,
            max_series: 1,
        },
    );

    assert_eq!(
        record.payload_kind,
        addon_sdk::pb::TelemetryPayloadKind::OcsfEvent as i32
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
    assert_eq!(event["class_uid"], OCSF_CLASS_EVENT_LOG_ACTIVITY);
    assert_eq!(event["status_code"], "anomaly_capacity_shed");
    assert_eq!(event["unmapped"]["dropped_series_delta"], 3);
    assert_eq!(event["unmapped"]["dropped_series_total"], 10);
    assert_eq!(event["unmapped"]["tracked_counters"], 2);
    assert!(event.get("anomaly").is_none());
    assert_ne!(
        event.get("event_type").and_then(|v| v.as_str()),
        Some("anomaly")
    );
    assert_eq!(
        record
            .metadata
            .get(addon_sdk::SIGNAL_SCHEMA_METADATA_SCHEMA_ID)
            .map(String::as_str),
        Some("com.carverauto.anomaly.capacity_shed")
    );
}

#[test]
fn emission_shed_record_accounts_governed_transitions() {
    let resource = MetricResource {
        agent_id: "agent-a".to_string(),
        host_id: "host-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let record = emission_shed_record(
        &resource,
        43,
        EmissionShedReport {
            detected_transitions: 5,
            emitted_transitions: 2,
            compacted_transitions: 1,
            cooldown_suppressed: 1,
            budget_shed: 1,
            storm_active: true,
            storm_entered: true,
            storm_exited: false,
            metric_class_counts: vec![("custom".to_string(), 3)],
            top_series: vec![EmissionShedSeries {
                series_key: "series-a".to_string(),
                metric_class: "custom".to_string(),
                count: 3,
            }],
        },
    );

    assert_eq!(
        record.payload_kind,
        addon_sdk::pb::TelemetryPayloadKind::OcsfEvent as i32
    );
    let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
    assert_eq!(event["class_uid"], OCSF_CLASS_EVENT_LOG_ACTIVITY);
    assert_eq!(event["status_code"], "anomaly_emission_shed");
    assert_eq!(event["unmapped"]["detected_transitions"], 5);
    assert_eq!(event["unmapped"]["emitted_transitions"], 2);
    assert_eq!(event["unmapped"]["accounted_transitions"], 3);
    assert_eq!(event["unmapped"]["compacted_transitions"], 1);
    assert_eq!(event["unmapped"]["cooldown_suppressed"], 1);
    assert_eq!(event["unmapped"]["budget_shed"], 1);
    assert_eq!(event["unmapped"]["storm_entered"], true);
    assert_eq!(event["unmapped"]["metric_class_counts"][0]["count"], 3);
    assert_eq!(event["unmapped"]["top_series"][0]["series_key"], "series-a");
    assert!(event.get("anomaly").is_none());
    assert_eq!(
        record
            .metadata
            .get(addon_sdk::SIGNAL_SCHEMA_METADATA_SCHEMA_ID)
            .map(String::as_str),
        Some("com.carverauto.anomaly.emission_shed")
    );
}
