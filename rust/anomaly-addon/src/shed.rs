// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Capacity-shed reporting: a non-causal operational OCSF Event Log Activity that
//! surfaces add-on pressure without polluting anomaly counts.

use addon_sdk::metric_pb::MetricResource;
use addon_sdk::pb::TelemetryRecord;
use addon_sdk::{SignalSchemaRef, attach_signal_schema_ref, ocsf_event_record};

use crate::checkpoint::now_unix_nano;
use crate::config::{
    ADDON_ID, ADDON_VERSION, OCSF_ACTIVITY_CREATE, OCSF_CATEGORY_SYSTEM_ACTIVITY,
    OCSF_CLASS_EVENT_LOG_ACTIVITY, OCSF_VERSION,
};
use crate::verdict::first_non_empty;

#[derive(Debug, Clone, Copy)]
pub(crate) struct ShedReport {
    pub(crate) dropped_delta: u64,
    pub(crate) dropped_total: u64,
    pub(crate) tracked_series: usize,
    pub(crate) tracked_counters: usize,
    pub(crate) max_series: usize,
}

/// Build a non-causal operational OCSF Event Log Activity for capacity shedding.
/// This is intentionally not an anomaly finding: it reports add-on pressure so
/// operators can tune `max_series` or targeting without polluting anomaly counts.
pub(crate) fn shed_record(
    resource: &MetricResource,
    feed_id: u64,
    report: ShedReport,
) -> TelemetryRecord {
    let ts_nano = now_unix_nano();
    let event_id = format!(
        "anomaly:shed:{}:{feed_id}:{}",
        first_non_empty(&[
            resource.agent_id.as_str(),
            resource.host_id.as_str(),
            resource.device_id.as_str(),
            "unknown",
        ]),
        report.dropped_total
    );

    let body = serde_json::json!({
        "id": &event_id,
        "time": ts_nano as i64,
        "class_uid": OCSF_CLASS_EVENT_LOG_ACTIVITY,
        "category_uid": OCSF_CATEGORY_SYSTEM_ACTIVITY,
        "type_uid": OCSF_CLASS_EVENT_LOG_ACTIVITY * 100 + OCSF_ACTIVITY_CREATE,
        "activity_id": OCSF_ACTIVITY_CREATE,
        "activity_name": "Create",
        "severity_id": 3,
        "severity": "Medium",
        "status_id": 1,
        "status": "Success",
        "status_code": "anomaly_capacity_shed",
        "message": format!(
            "Anomaly add-on shed {} new series at capacity ({} detector series, {} counters of max {})",
            report.dropped_delta, report.tracked_series, report.tracked_counters, report.max_series
        ),
        "log_name": "anomaly.capacity",
        "log_provider": ADDON_ID,
        "actor": { "app_name": "serviceradar-anomaly-addon" },
        "device": {
            "uid": first_non_empty(&[
                resource.device_id.as_str(),
                resource.host_id.as_str(),
                resource.agent_id.as_str(),
                resource.host_ip.as_str(),
            ])
        },
        "observables": [],
        "metadata": {
            "version": OCSF_VERSION,
            "product": {
                "name": "ServiceRadar Anomaly Add-on",
                "vendor_name": "Carver Automation"
            }
        },
        "unmapped": {
            "addon_id": ADDON_ID,
            "event_kind": "capacity_shed",
            "feed_id": feed_id,
            "agent_id": &resource.agent_id,
            "host_id": &resource.host_id,
            "device_id": &resource.device_id,
            "host_ip": &resource.host_ip,
            "partition": &resource.partition,
            "dropped_series_delta": report.dropped_delta,
            "dropped_series_total": report.dropped_total,
            "tracked_series": report.tracked_series,
            "tracked_counters": report.tracked_counters,
            "max_series": report.max_series
        }
    });

    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let record = ocsf_event_record(event_id, ts_nano as i64, ts_nano as i64, payload);
    attach_signal_schema_ref(record, &shed_signal_schema_ref())
}

pub(crate) fn shed_signal_schema_ref() -> SignalSchemaRef {
    SignalSchemaRef {
        producer_id: ADDON_ID.to_string(),
        producer_version: ADDON_VERSION.to_string(),
        schema_id: "com.carverauto.anomaly.capacity_shed".to_string(),
        schema_version: "1.0.0".to_string(),
        display_contract_id: "com.carverauto.anomaly.capacity_shed.display".to_string(),
        display_contract_version: "1.0.0".to_string(),
        display_contract: "display/capacity_shed.display.json".to_string(),
        signal_type: "event".to_string(),
        payload_kind: "ocsf_event".to_string(),
    }
}
