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
use sha2::{Digest as _, Sha256};

use crate::config::{ADDON_ID, ADDON_VERSION};
use crate::engine::{
    AnomalyEpisode, AnomalyTransition, CusumDrift, SeverityPolicy, SpikeClearReason,
    SpikeUpdateReason,
};
use crate::identity::{
    anomaly_device_uid, attested_tags, entry_value, metric_class, target_device_ip_for,
};
use crate::metrics_classify::{
    GaugeClass, gauge_class, is_cumulative_counter, is_utilization_percent_gauge,
};

const MAX_STORED_ANOMALY_SCORE: f64 = 50.0;
const EPISODE_UID_NAMESPACE: &str = "serviceradar:anomaly:detection_finding:episode:v1";

#[derive(Clone, Copy, Debug)]
pub(crate) struct VerdictRecordOptions {
    pub(crate) transition: AnomalyTransition,
    pub(crate) episode: Option<AnomalyEpisode>,
    pub(crate) critical_min_duration_secs: u64,
    pub(crate) abs_effect_floor: f64,
    pub(crate) severity_policy: SeverityPolicy,
    pub(crate) clear_reason: Option<SpikeClearReason>,
    pub(crate) update_reason: Option<SpikeUpdateReason>,
    pub(crate) reopen_count: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct CusumDriftRecordOptions {
    pub(crate) drift_escalate_after_secs: u64,
    pub(crate) severity_policy: SeverityPolicy,
}

/// Build an OCSF Detection Finding (class_uid 2004) shaped to match the central
/// `VerdictEmitter` envelope, so core consumes an edge verdict identically. The
/// canonical `series_key` is computed CENTRALLY from gateway-attested fields, so
/// `source_identity` carries the raw resource identity for central re-keying;
/// the `series_key` here is the producer hint (provisional / for dedup).
/// `verdict_source: edge-spike` is the discriminator the edge<->central join uses.
#[cfg(test)]
pub(crate) fn verdict_record(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
    series_key: &str,
    verdict: &ReasonVerdict,
    transition: AnomalyTransition,
    episode: Option<AnomalyEpisode>,
) -> TelemetryRecord {
    verdict_record_with_policy(
        resource,
        metric,
        point,
        series_key,
        verdict,
        VerdictRecordOptions {
            transition,
            episode,
            critical_min_duration_secs: crate::engine::DEFAULT_CRITICAL_MIN_DURATION_SECS,
            abs_effect_floor: 0.0,
            severity_policy: SeverityPolicy::default(),
            clear_reason: None,
            update_reason: None,
            reopen_count: 0,
        },
    )
}

pub(crate) fn verdict_record_with_policy(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
    series_key: &str,
    verdict: &ReasonVerdict,
    options: VerdictRecordOptions,
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
    let score = bounded_score(verdict.score);
    let severity_id = spike_severity_id(metric, point, verdict, confirmed, &options);
    let lifecycle_state = anomaly_lifecycle_state(options.transition);
    let transition_name = anomaly_transition_name(options.transition);
    let status = anomaly_lifecycle_status(options.transition);
    let clear_reason = options.clear_reason.map(SpikeClearReason::as_str);
    let update_reason = options.update_reason.map(SpikeUpdateReason::as_str);
    let lifecycle_reason = match options.transition {
        AnomalyTransition::Clear => clear_reason.unwrap_or(&verdict.reason),
        AnomalyTransition::Update => update_reason.unwrap_or(&verdict.reason),
        AnomalyTransition::Open | AnomalyTransition::None => &verdict.reason,
    };
    let message = anomaly_lifecycle_message(options.transition, lifecycle_reason);

    let metric_class = metric_class(metric);
    let device_uid = anomaly_device_uid(resource, metric_class, metric, point);
    let target_device_ip = target_device_ip_for(resource, metric_class, metric, point);
    let signals = anomaly_signals(verdict);

    let finding_uid =
        format!("anomaly:finding:2004:anomaly_detection:{device_uid}:{series_key}:{metric_class}");
    let episode_started_at_unix_nano = options
        .episode
        .map(|episode| episode.started_at_unix_nano)
        .unwrap_or(ts_nano);
    let episode_uid = episode_uid_for(&finding_uid, episode_started_at_unix_nano);
    let event_id = transition_event_id(&episode_uid, transition_name, severity_id);

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
        "producer_id": ADDON_ID,
        "producer_version": ADDON_VERSION,
        "verdict_source": "edge-spike",
        "finding_uid": &finding_uid,
        "episode_uid": &episode_uid,
        "transition": transition_name,
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
            "clear_reason": clear_reason,
            "update_reason": update_reason,
            "score": score,
            "producer_id": ADDON_ID,
            "producer_version": ADDON_VERSION,
            "finding_uid": &finding_uid,
            "episode_uid": &episode_uid,
            "transition": transition_name,
            "reopen_count": options.reopen_count,
            "baseline_count": verdict.baseline_count,
            "consecutive_anomalous": verdict.next_consecutive_anomalous,
            "value": verdict.sample_value,
            "sample_value": verdict.sample_value,
            "observed_at_unix_nano": ts_nano,
            "episode_started_at_unix_nano": episode_started_at_unix_nano,
            "episode_ended_at_unix_nano": options.episode.map(|episode| episode.ended_at_unix_nano),
            "episode_peak_value": options.episode.map(|episode| episode.peak_value),
            "episode_peak_at_unix_nano": options.episode.map(|episode| episode.peak_at_unix_nano),
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
#[cfg(test)]
pub(crate) fn cusum_drift_record(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
    series_key: &str,
    verdict: &ReasonVerdict,
    drift: CusumDrift,
) -> TelemetryRecord {
    cusum_drift_record_with_policy(
        resource,
        metric,
        point,
        series_key,
        verdict,
        drift,
        CusumDriftRecordOptions {
            drift_escalate_after_secs: crate::engine::DEFAULT_DRIFT_ESCALATE_AFTER_SECS,
            severity_policy: SeverityPolicy::default(),
        },
    )
}

pub(crate) fn cusum_drift_record_with_policy(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
    series_key: &str,
    verdict: &ReasonVerdict,
    drift: CusumDrift,
    options: CusumDriftRecordOptions,
) -> TelemetryRecord {
    let ts_nano = verdict
        .observed_at_unix_nano
        .unwrap_or(point.observed_at_unix_nano);
    let ts_ms = (ts_nano / 1_000_000) as i64;
    let magnitude = bounded_score(drift.magnitude());
    let severity_id = options.severity_policy.capped(drift_severity_id(
        drift,
        magnitude,
        ts_nano,
        options.drift_escalate_after_secs,
    ));
    let direction = drift.direction.as_str();
    let reason = format!("sustained {direction} drift");
    let transition_name = anomaly_transition_name(drift.transition);
    let status = anomaly_lifecycle_status(drift.transition);
    let drift_state = drift_lifecycle_state(drift.transition);
    let clear_reason = drift.clear_reason.map(|reason| reason.as_str());
    let update_reason = drift.update_reason.map(|reason| reason.as_str());
    let message = match drift.transition {
        AnomalyTransition::Open => reason.clone(),
        AnomalyTransition::Update => update_reason.map_or_else(
            || format!("sustained {direction} drift still open"),
            |reason| format!("sustained {direction} drift update: {reason}"),
        ),
        AnomalyTransition::Clear => clear_reason.map_or_else(
            || format!("sustained {direction} drift cleared"),
            |reason| format!("sustained {direction} drift cleared: {reason}"),
        ),
        AnomalyTransition::None => reason.clone(),
    };

    let metric_class = metric_class(metric);
    let device_uid = anomaly_device_uid(resource, metric_class, metric, point);
    let target_device_ip = target_device_ip_for(resource, metric_class, metric, point);
    let signals = anomaly_signals(verdict);

    let finding_uid = format!(
        "anomaly:finding:2004:anomaly_detection:drift:{device_uid}:{series_key}:{metric_class}"
    );
    let episode_started_at_unix_nano = drift
        .episode
        .map(|episode| episode.started_at_unix_nano)
        .unwrap_or(ts_nano);
    let episode_uid = episode_uid_for(&finding_uid, episode_started_at_unix_nano);
    let event_id = transition_event_id(&episode_uid, transition_name, severity_id);

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
        "producer_id": ADDON_ID,
        "producer_version": ADDON_VERSION,
        "verdict_source": "edge-drift",
        "finding_uid": &finding_uid,
        "episode_uid": &episode_uid,
        "transition": transition_name,
        "status": status,
        "time": ts_ms,
        "severity_id": severity_id,
        "device_uid": device_uid,
        "device_id": device_uid,
        "target_device_ip": target_device_ip,
        "message": &message,
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
            "state": drift_state,
            "lifecycle_state": anomaly_lifecycle_state(drift.transition),
            "target_device_ip": target_device_ip,
            "detector_method": "cusum_drift",
            "detector_state": &verdict.state,
            "reason": &reason,
            "drift_direction": direction,
            "clear_reason": clear_reason,
            "update_reason": update_reason,
            "score": magnitude,
            "producer_id": ADDON_ID,
            "producer_version": ADDON_VERSION,
            "finding_uid": &finding_uid,
            "episode_uid": &episode_uid,
            "transition": transition_name,
            "reopen_count": drift.reopen_count,
            "cusum_pos": drift.pos,
            "cusum_neg": drift.neg,
            "baseline_count": verdict.baseline_count,
            "value": verdict.sample_value,
            "sample_value": verdict.sample_value,
            "observed_at_unix_nano": ts_nano,
            "episode_started_at_unix_nano": episode_started_at_unix_nano,
            "episode_ended_at_unix_nano": drift.episode.map(|episode| episode.ended_at_unix_nano),
            "episode_peak_value": drift.episode.map(|episode| episode.peak_value),
            "episode_peak_at_unix_nano": drift.episode.map(|episode| episode.peak_at_unix_nano),
            "signals": signals,
        },
    });

    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let record = ocsf_event_record(event_id, ts_nano as i64, ts_nano as i64, payload);
    attach_signal_schema_ref(record, &anomaly_signal_schema_ref())
}

fn drift_lifecycle_state(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "anomaly_drift_open",
        AnomalyTransition::Update => "anomaly_drift_update",
        AnomalyTransition::Clear => "anomaly_drift_clear",
        AnomalyTransition::None => "anomaly_drift",
    }
}

pub(crate) fn anomaly_lifecycle_state(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "anomaly_open",
        AnomalyTransition::Update => "anomaly_update",
        AnomalyTransition::Clear => "anomaly_clear",
        AnomalyTransition::None => "none",
    }
}

pub(crate) fn anomaly_transition_name(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "open",
        AnomalyTransition::Update => "update",
        AnomalyTransition::Clear => "clear",
        AnomalyTransition::None => "none",
    }
}

pub(crate) fn anomaly_lifecycle_status(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "open",
        AnomalyTransition::Update => "open",
        AnomalyTransition::Clear => "inactive",
        AnomalyTransition::None => "suppressed",
    }
}

pub(crate) fn anomaly_lifecycle_message(transition: AnomalyTransition, reason: &str) -> String {
    match transition {
        AnomalyTransition::Open => reason.to_string(),
        AnomalyTransition::Update => format!("anomaly updated: {reason}"),
        AnomalyTransition::Clear => format!("anomaly cleared: {reason}"),
        AnomalyTransition::None => reason.to_string(),
    }
}

fn spike_severity_id(
    metric: &Metric,
    point: &MetricPoint,
    verdict: &ReasonVerdict,
    confirmed: bool,
    options: &VerdictRecordOptions,
) -> i64 {
    let severity_policy = options.severity_policy;
    let score = bounded_score(verdict.score);
    let base = severity_id_from_score_with_policy(score, confirmed, severity_policy);

    if !confirmed {
        return severity_policy.capped(base);
    }

    if !practical_significance_passes(metric, verdict, options.abs_effect_floor) {
        return severity_policy.capped(2);
    }

    if base < 4 {
        return severity_policy.capped(base);
    }

    if is_per_core_cpu(metric, point) {
        return severity_policy.capped(4);
    }

    let severity_id = if critical_impact_passes(metric, verdict, options.episode)
        && episode_duration_at_least(options.episode, options.critical_min_duration_secs)
    {
        5
    } else {
        4
    };
    severity_policy.capped(severity_id)
}

fn drift_severity_id(
    drift: CusumDrift,
    magnitude: f64,
    ts_nano: u64,
    drift_escalate_after_secs: u64,
) -> i64 {
    if drift.transition == AnomalyTransition::Update
        && magnitude >= 8.0
        && drift.episode.is_some_and(|episode| {
            ts_nano.saturating_sub(episode.started_at_unix_nano)
                >= seconds_to_ns(drift_escalate_after_secs.max(1))
        })
    {
        4
    } else {
        3
    }
}

/// Confirmation-aware OCSF severity for bounded anomaly evidence.
///
/// This base band table deliberately stops at High. Critical is not a score
/// cutpoint: callers must additionally prove class impact and duration.
#[cfg(test)]
pub(crate) fn severity_id_from_score(score: f64, confirmed: bool) -> i64 {
    severity_id_from_score_with_policy(score, confirmed, SeverityPolicy::default())
}

fn severity_id_from_score_with_policy(
    score: f64,
    confirmed: bool,
    severity_policy: SeverityPolicy,
) -> i64 {
    if !confirmed {
        return 2;
    }

    let (medium_at, high_at) = severity_policy.bands();

    if score >= high_at {
        4
    } else if score >= medium_at {
        3
    } else {
        2
    }
}

fn practical_significance_passes(
    metric: &Metric,
    verdict: &ReasonVerdict,
    abs_effect_floor: f64,
) -> bool {
    if is_utilization_percent_gauge(metric) {
        return signal_center(verdict)
            .is_none_or(|center| (verdict.sample_value - center).abs() >= 5.0);
    }

    if is_cumulative_counter(metric) {
        return signal_center(verdict).is_none_or(|center| {
            let delta = (verdict.sample_value - center).abs();
            let relative_floor = 0.30 * center.abs();
            delta >= relative_floor.max(abs_effect_floor.max(0.0))
        });
    }

    true
}

fn critical_impact_passes(
    metric: &Metric,
    verdict: &ReasonVerdict,
    episode: Option<AnomalyEpisode>,
) -> bool {
    let Some(threshold) = critical_saturation_threshold(metric) else {
        return false;
    };
    let peak = episode.map_or(verdict.sample_value, |episode| episode.peak_value);
    peak >= threshold
}

fn critical_saturation_threshold(metric: &Metric) -> Option<f64> {
    match gauge_class(metric) {
        Some(GaugeClass::Cpu) => Some(85.0),
        Some(GaugeClass::Mem) => Some(80.0),
        Some(GaugeClass::Disk) | None => None,
    }
}

fn is_per_core_cpu(metric: &Metric, point: &MetricPoint) -> bool {
    matches!(gauge_class(metric), Some(GaugeClass::Cpu))
        && entry_value(&metric.tags, &["core_id"])
            .or_else(|| entry_value(&point.attributes, &["core_id"]))
            .is_some()
}

fn signal_center(verdict: &ReasonVerdict) -> Option<f64> {
    verdict
        .signals
        .iter()
        .find_map(|signal| signal.mean.filter(|mean| mean.is_finite()))
}

fn episode_duration_at_least(episode: Option<AnomalyEpisode>, seconds: u64) -> bool {
    episode.is_some_and(|episode| {
        episode
            .ended_at_unix_nano
            .saturating_sub(episode.started_at_unix_nano)
            >= seconds_to_ns(seconds.max(1))
    })
}

fn seconds_to_ns(seconds: u64) -> u64 {
    seconds.saturating_mul(1_000_000_000)
}

fn bounded_score(score: f64) -> f64 {
    if !score.is_finite() || score < 0.0 {
        0.0
    } else {
        score.min(MAX_STORED_ANOMALY_SCORE)
    }
}

fn episode_uid_for(finding_uid: &str, episode_started_at_unix_nano: u64) -> String {
    deterministic_uuid_like(&format!(
        "{EPISODE_UID_NAMESPACE}:{finding_uid}:{episode_started_at_unix_nano}"
    ))
}

fn transition_event_id(episode_uid: &str, transition: &str, severity_id: i64) -> String {
    format!("anomaly:{episode_uid}:{transition}:severity-{severity_id}")
}

fn deterministic_uuid_like(name: &str) -> String {
    let digest = Sha256::digest(name.as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
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
        display_contract_version: "1.1.0".to_string(),
        display_contract: "display/detection_finding.display.json".to_string(),
        signal_type: "event".to_string(),
        payload_kind: "ocsf_event".to_string(),
    }
}
