// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::metric_pb::MetricResource;

use crate::config::OCSF_CLASS_EVENT_LOG_ACTIVITY;
use crate::shed::{ShedReport, shed_record};

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
