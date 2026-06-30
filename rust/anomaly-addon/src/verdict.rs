// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The edge verdict OCSF Detection Finding record and its lifecycle/severity
//! helpers.

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource};
use addon_sdk::pb::TelemetryRecord;
use addon_sdk::{SignalSchemaRef, attach_signal_schema_ref, ocsf_event_record};
use serviceradar_anomaly_core::{ReasonVerdict, SignalVerdict};

use crate::config::{ADDON_ID, ADDON_VERSION};
use crate::engine::{AnomalyEpisode, AnomalyTransition, CusumDrift};
use crate::identity::{anomaly_device_uid, attested_tags, metric_class, target_device_ip_for};

/// Build an OCSF Detection Finding (class_uid 2004) shaped to match the central
/// `VerdictEmitter` envelope, so core consumes an edge verdict identically. The
/// canonical `series_key` is computed CENTRALLY from gateway-attested fields, so
/// `source_identity` carries the raw resource identity for central re-keying;
/// the `series_key` here is the producer hint (provisional / for dedup).
/// `verdict_source: edge-spike` is the discriminator the edge<->central join uses.
pub(crate) fn verdict_record(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
    series_key: &str,
    verdict: &ReasonVerdict,
    transition: AnomalyTransition,
    episode: Option<AnomalyEpisode>,
) -> TelemetryRecord {
    let ts_nano = verdict
        .observed_at_unix_nano
        .unwrap_or(point.observed_at_unix_nano);
    let ts_ms = (ts_nano / 1_000_000) as i64;
    // Confirmation-aware severity: a pending breadcrumb (a single breaching slot
    // that has not yet reached `confirm_slots`, i.e. `detector_state ==
    // "pending_anomaly"` / `!verdict.anomalous`) must never escalate past Low even
    // when its raw z-score is large; only a CONFIRMED anomaly reaches High/Critical.
    let confirmed = verdict.anomalous && verdict.state != "pending_anomaly";
    let severity_id = severity_id_from_score(verdict.score, confirmed);
    let lifecycle_state = anomaly_lifecycle_state(transition);
    let status = anomaly_lifecycle_status(transition);
    let message = anomaly_lifecycle_message(transition, &verdict.reason);

    let metric_class = metric_class(metric);
    let device_uid = anomaly_device_uid(resource, metric_class, metric, point);
    let target_device_ip = target_device_ip_for(resource, metric_class, metric, point);
    let signals = anomaly_signals(verdict);

    let event_id = format!("anomaly:{series_key}:{ts_nano}:{lifecycle_state}");
    let finding_uid =
        format!("anomaly:finding:2004:anomaly_detection:{device_uid}:{series_key}:{metric_class}");

    // 1.1 wire-value flip: emit the honest `signal_type:"prediction"` (this detector is a
    // rolling robust z-score, NOT causal inference) now that consumers dual-read
    // ["causal","prediction"] and the seeded rule definitions dual-match. Already-seeded
    // deployments still need the rule data migration to dual-match before this ships live
    // (rollout step 1.f4). `detector_method` stays alongside as the precise classifier.
    let body = serde_json::json!({
        "event_id": &event_id,
        "id": &event_id,
        "signal_type": "prediction",
        "detector_method": "rolling_robust_zscore",
        "event_type": "anomaly",
        "class_uid": 2004,
        "category_uid": 2,
        "type_uid": 200_401,
        "activity_id": 1,
        "finding_type": "detection",
        "provider": "anomaly_detection",
        "source": "serviceradar",
        "collector": "anomaly_addon",
        "verdict_source": "edge-spike",
        "status": status,
        "time": ts_ms,
        "severity_id": severity_id,
        "device_uid": device_uid,
        "device_id": device_uid,
        "target_device_ip": target_device_ip,
        "message": message,
        "finding_info": {
            "uid": finding_uid,
            "title": format!("{metric_class} anomaly on {device_uid}"),
            "type": "anomaly",
            "type_id": 99,
        },
        "source_identity": {
            "series_key": series_key,
            "metric_class": metric_class,
            "agent_id": &resource.agent_id,
            "host_id": &resource.host_id,
            "device_id": &resource.device_id,
            "host_ip": &resource.host_ip,
            "target_device_ip": target_device_ip,
            "partition": &resource.partition,
            "metric_name": &metric.name,
            "if_index": point.if_index,
            "interface_uid": &point.interface_uid,
            // Attested distinguishing tags (metric.tags ∪ point.attributes) so
            // central can reconstruct the exact per-core/per-mount/per-tag series
            // dimension; central applies its own identity/volatile-key exclusions.
            "tags": attested_tags(metric, point),
        },
        "anomaly": {
            "series_key": series_key,
            "metric_class": metric_class,
            "state": lifecycle_state,
            "target_device_ip": target_device_ip,
            "detector_state": &verdict.state,
            "reason": &verdict.reason,
            "score": verdict.score,
            "baseline_count": verdict.baseline_count,
            "consecutive_anomalous": verdict.next_consecutive_anomalous,
            "value": verdict.sample_value,
            "sample_value": verdict.sample_value,
            "observed_at_unix_nano": ts_nano,
            "episode_started_at_unix_nano": episode.map(|episode| episode.started_at_unix_nano),
            "episode_ended_at_unix_nano": episode.map(|episode| episode.ended_at_unix_nano),
            "episode_peak_value": episode.map(|episode| episode.peak_value),
            "episode_peak_at_unix_nano": episode.map(|episode| episode.peak_at_unix_nano),
            "signals": signals,
        },
    });

    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let record = ocsf_event_record(event_id, ts_nano as i64, ts_nano as i64, payload);
    attach_signal_schema_ref(record, &anomaly_signal_schema_ref())
}

/// Build an OCSF Detection Finding for a CUSUM SUSTAINED-DRIFT alarm — distinct
/// from the z-score SPIKE [`verdict_record`]. Same envelope/class so core consumes
/// it identically, but marked `detector_method: "cusum_drift"` /
/// `verdict_source: "edge-drift"` and a `sustained drift` reason so a gradual
/// drift/leak is distinguishable downstream from a point spike. The `verdict` is
/// the same sample's z-score verdict, carried for value/baseline/signal evidence
/// (it did NOT itself breach — that is why CUSUM is the one reporting).
pub(crate) fn cusum_drift_record(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
    series_key: &str,
    verdict: &ReasonVerdict,
    drift: CusumDrift,
) -> TelemetryRecord {
    let ts_nano = verdict
        .observed_at_unix_nano
        .unwrap_or(point.observed_at_unix_nano);
    let ts_ms = (ts_nano / 1_000_000) as i64;
    let magnitude = drift.magnitude();
    // A CUSUM sustained-drift alarm is confirmed by construction (it requires the
    // accumulated drift to cross the alarm threshold over multiple samples), so it
    // carries its full magnitude-derived severity.
    let severity_id = severity_id_from_score(magnitude, true);
    let direction = drift.direction.as_str();
    let reason = format!("sustained {direction} drift");

    let metric_class = metric_class(metric);
    let device_uid = anomaly_device_uid(resource, metric_class, metric, point);
    let target_device_ip = target_device_ip_for(resource, metric_class, metric, point);
    let signals = anomaly_signals(verdict);

    let event_id = format!("anomaly:{series_key}:{ts_nano}:drift");
    let finding_uid = format!(
        "anomaly:finding:2004:anomaly_detection:drift:{device_uid}:{series_key}:{metric_class}"
    );

    let body = serde_json::json!({
        "event_id": &event_id,
        "id": &event_id,
        "signal_type": "prediction",
        "detector_method": "cusum_drift",
        "event_type": "anomaly",
        "class_uid": 2004,
        "category_uid": 2,
        "type_uid": 200_401,
        "activity_id": 1,
        "finding_type": "detection",
        "provider": "anomaly_detection",
        "source": "serviceradar",
        "collector": "anomaly_addon",
        "verdict_source": "edge-drift",
        "status": "open",
        "time": ts_ms,
        "severity_id": severity_id,
        "device_uid": device_uid,
        "device_id": device_uid,
        "target_device_ip": target_device_ip,
        "message": &reason,
        "finding_info": {
            "uid": finding_uid,
            "title": format!("{metric_class} sustained drift on {device_uid}"),
            "type": "anomaly",
            "type_id": 99,
        },
        "source_identity": {
            "series_key": series_key,
            "metric_class": metric_class,
            "agent_id": &resource.agent_id,
            "host_id": &resource.host_id,
            "device_id": &resource.device_id,
            "host_ip": &resource.host_ip,
            "target_device_ip": target_device_ip,
            "partition": &resource.partition,
            "metric_name": &metric.name,
            "if_index": point.if_index,
            "interface_uid": &point.interface_uid,
            "tags": attested_tags(metric, point),
        },
        "anomaly": {
            "series_key": series_key,
            "metric_class": metric_class,
            "state": "anomaly_drift",
            "target_device_ip": target_device_ip,
            "detector_method": "cusum_drift",
            "detector_state": &verdict.state,
            "reason": &reason,
            "drift_direction": direction,
            "score": magnitude,
            "cusum_pos": drift.pos,
            "cusum_neg": drift.neg,
            "baseline_count": verdict.baseline_count,
            "value": verdict.sample_value,
            "sample_value": verdict.sample_value,
            "observed_at_unix_nano": ts_nano,
            "signals": signals,
        },
    });

    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let record = ocsf_event_record(event_id, ts_nano as i64, ts_nano as i64, payload);
    attach_signal_schema_ref(record, &anomaly_signal_schema_ref())
}

pub(crate) fn anomaly_lifecycle_state(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "anomaly_open",
        AnomalyTransition::Clear => "anomaly_clear",
        AnomalyTransition::None => "none",
    }
}

pub(crate) fn anomaly_lifecycle_status(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "open",
        AnomalyTransition::Clear => "inactive",
        AnomalyTransition::None => "suppressed",
    }
}

pub(crate) fn anomaly_lifecycle_message(transition: AnomalyTransition, reason: &str) -> String {
    match transition {
        AnomalyTransition::Open => reason.to_string(),
        AnomalyTransition::Clear => format!("anomaly cleared: {reason}"),
        AnomalyTransition::None => reason.to_string(),
    }
}

/// Confirmation-aware OCSF severity for an anomaly verdict.
///
/// The raw rolling robust z-score (or CUSUM drift magnitude) maps to a base
/// severity, but an UNCONFIRMED breadcrumb (`!confirmed`, i.e. `detector_state ==
/// "pending_anomaly"` / a single breaching slot that has not reached
/// `confirm_slots`) must never escalate past Low (severity_id 2) — a pending
/// anomaly is a breadcrumb, not a High/Critical alert. Only a CONFIRMED anomaly
/// reaches Medium/High/Critical. This mirrors the central consumer backstop in
/// `ServiceRadar.EventWriter.Processors.AnalyticsSignals`.
pub(crate) fn severity_id_from_score(score: f64, confirmed: bool) -> i64 {
    let base = if score >= 6.0 {
        5
    } else if score >= 3.0 {
        4
    } else if score >= 2.0 {
        3
    } else {
        2
    };

    if confirmed { base } else { base.min(2) }
}

fn anomaly_signals(verdict: &ReasonVerdict) -> Vec<serde_json::Value> {
    verdict.signals.iter().map(signal_json).collect()
}

fn signal_json(signal: &SignalVerdict) -> serde_json::Value {
    serde_json::json!({
        "name": &signal.name,
        "enabled": signal.enabled,
        "ready": signal.ready,
        "breached": signal.breached,
        "score": signal.score,
        "threshold": signal.threshold,
        "sample_count": signal.sample_count,
        "mean": signal.mean,
        "stddev": signal.stddev,
        "reason": &signal.reason,
    })
}

pub(crate) fn first_non_empty<'a>(candidates: &[&'a str]) -> &'a str {
    candidates
        .iter()
        .copied()
        .find(|s| !s.is_empty())
        .unwrap_or("unknown")
}

pub(crate) fn anomaly_signal_schema_ref() -> SignalSchemaRef {
    SignalSchemaRef {
        producer_id: ADDON_ID.to_string(),
        producer_version: ADDON_VERSION.to_string(),
        schema_id: "com.carverauto.anomaly.detection_finding".to_string(),
        schema_version: "1.0.0".to_string(),
        display_contract_id: "com.carverauto.anomaly.detection_finding.display".to_string(),
        display_contract_version: "1.0.0".to_string(),
        display_contract: "display/detection_finding.display.json".to_string(),
        signal_type: "event".to_string(),
        payload_kind: "ocsf_event".to_string(),
    }
}
