// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Per-frame scoring: decode a metric-feed frame, score every eligible point, and
//! push verdict telemetry; plus the broadcast->mpsc telemetry stream bridge.

use std::collections::{BTreeMap, HashSet};
use std::sync::{Arc, Mutex};

use addon_sdk::TelemetryBatchBuilder;
use addon_sdk::metric_pb::{Metric, MetricBatch, MetricPoint, MetricResource, StringMapEntry};
use addon_sdk::pb::{MetricFeedFrame, TelemetryBatch, TelemetryRecord};
use prost::Message;
use tokio::sync::{broadcast, mpsc};
use tokio_stream::wrappers::ReceiverStream;
use tonic::Status;

use crate::addon::{lock_engine, lock_scoring_health};
use crate::config::{NativeTelemetryDropCounters, VERDICT_CHANNEL_DEPTH};
use crate::engine::{
    AnomalyTransition, DetectorEngine, EngineConfig, HostCpuAggregateSample, SeriesProfile,
    SeverityPolicy, TransitionVerdict,
};
use crate::health::{ScoringFrameUpdate, ScoringHealth};
use crate::identity::{
    entry_value, is_snmp_metric_class, metric_class, seasonal_series_key, series_key_for,
    snmp_polled_device_identity,
};
use crate::metrics_classify::{
    CPU_EVALUATION_INTERVAL_NS, GaugeClass, counter_raw_value, counter_reset_anchor,
    counter_series_profile, counter_width, gauge_class, host_cpu_aggregate_profile,
    is_cumulative_counter, is_process_metric, max_counter_rate_per_second, metric_profile_class,
    series_profile_for,
};
use crate::shed::{
    EmissionShedReport, EmissionShedSeries, ShedReport, emission_shed_record, shed_record,
};
use crate::verdict::{
    CusumDriftRecordOptions, VerdictRecordOptions, cusum_drift_record_with_policy,
    verdict_record_with_policy,
};
use addon_sdk::TelemetryStream;

const OPEN_RESERVE_PERCENT: usize = 20;
const EMISSION_TOP_SERIES_LIMIT: usize = 5;

#[derive(Debug)]
struct EmissionCandidate {
    record: TelemetryRecord,
    series_key: String,
    metric_class: String,
    transition: AnomalyTransition,
    severity_id: i64,
    observed_at_unix_nano: u64,
}

struct CandidateContext<'a> {
    engine_config: &'a EngineConfig,
    resource: &'a MetricResource,
    metric: &'a Metric,
    point: &'a MetricPoint,
    series_key: &'a str,
    metric_class: &'a str,
    profile: SeriesProfile,
    severity_policy: SeverityPolicy,
}

impl EmissionCandidate {
    fn new(
        record: TelemetryRecord,
        series_key: String,
        metric_class: String,
        transition: AnomalyTransition,
        observed_at_unix_nano: u64,
    ) -> Self {
        let severity_id = record_severity_id(&record);
        Self {
            record,
            series_key,
            metric_class,
            transition,
            severity_id,
            observed_at_unix_nano,
        }
    }
}

#[derive(Default)]
struct EmissionAccounting {
    compacted_transitions: u64,
    cooldown_suppressed: u64,
    budget_shed: u64,
    metric_class_counts: BTreeMap<String, u64>,
    series_counts: BTreeMap<String, (String, u64)>,
}

impl EmissionAccounting {
    fn account_compacted(&mut self, candidate: &EmissionCandidate) {
        self.compacted_transitions = self.compacted_transitions.saturating_add(1);
        self.account_candidate(candidate);
    }

    fn account_cooldown(&mut self, candidate: &EmissionCandidate) {
        self.cooldown_suppressed = self.cooldown_suppressed.saturating_add(1);
        self.account_candidate(candidate);
    }

    fn account_budget(&mut self, candidate: &EmissionCandidate) {
        self.budget_shed = self.budget_shed.saturating_add(1);
        self.account_candidate(candidate);
    }

    fn account_candidate(&mut self, candidate: &EmissionCandidate) {
        *self
            .metric_class_counts
            .entry(candidate.metric_class.clone())
            .or_insert(0) += 1;

        let entry = self
            .series_counts
            .entry(candidate.series_key.clone())
            .or_insert_with(|| (candidate.metric_class.clone(), 0));
        entry.1 = entry.1.saturating_add(1);
    }

    fn accounted_transitions(&self) -> u64 {
        self.compacted_transitions + self.cooldown_suppressed + self.budget_shed
    }

    fn into_report(
        self,
        detected_transitions: u64,
        emitted_transitions: u64,
        storm_active: bool,
        storm_entered: bool,
        storm_exited: bool,
    ) -> Option<EmissionShedReport> {
        if self.accounted_transitions() == 0 && !storm_entered && !storm_exited {
            return None;
        }

        let mut top_series: Vec<_> = self
            .series_counts
            .into_iter()
            .map(|(series_key, (metric_class, count))| EmissionShedSeries {
                series_key,
                metric_class,
                count,
            })
            .collect();
        top_series.sort_by(|left, right| {
            right
                .count
                .cmp(&left.count)
                .then_with(|| left.series_key.cmp(&right.series_key))
        });
        top_series.truncate(EMISSION_TOP_SERIES_LIMIT);

        Some(EmissionShedReport {
            detected_transitions,
            emitted_transitions,
            compacted_transitions: self.compacted_transitions,
            cooldown_suppressed: self.cooldown_suppressed,
            budget_shed: self.budget_shed,
            storm_active,
            storm_entered,
            storm_exited,
            metric_class_counts: self.metric_class_counts.into_iter().collect(),
            top_series,
        })
    }
}

fn push_evaluated_candidates(
    candidates: &mut Vec<EmissionCandidate>,
    ctx: CandidateContext<'_>,
    evaluated: TransitionVerdict,
) {
    if matches!(
        evaluated.transition,
        AnomalyTransition::Open | AnomalyTransition::Update | AnomalyTransition::Clear
    ) {
        let observed_at_unix_nano = evaluated
            .verdict
            .observed_at_unix_nano
            .unwrap_or(ctx.point.observed_at_unix_nano);
        let record = verdict_record_with_policy(
            ctx.resource,
            ctx.metric,
            ctx.point,
            ctx.series_key,
            &evaluated.verdict,
            VerdictRecordOptions {
                transition: evaluated.transition,
                episode: evaluated.episode,
                critical_min_duration_secs: ctx.engine_config.critical_min_duration_secs,
                abs_effect_floor: ctx.profile.abs_effect_floor,
                severity_policy: ctx.severity_policy,
                clear_reason: evaluated.clear_reason,
                update_reason: evaluated.update_reason,
                reopen_count: evaluated.reopen_count,
            },
        );
        candidates.push(EmissionCandidate::new(
            record,
            ctx.series_key.to_string(),
            ctx.metric_class.to_string(),
            evaluated.transition,
            observed_at_unix_nano,
        ));
    }

    // Additive sustained-drift finding: a CUSUM alarm the point z-score missed
    // (already gated against a same-sample breach in the engine), emitted
    // through the same OCSF path but marked `cusum_drift` so a gradual drift/leak
    // is distinct from a spike.
    if let Some(drift) = evaluated.cusum_drift {
        let observed_at_unix_nano = evaluated
            .verdict
            .observed_at_unix_nano
            .unwrap_or(ctx.point.observed_at_unix_nano);
        let transition = drift.transition;
        let record = cusum_drift_record_with_policy(
            ctx.resource,
            ctx.metric,
            ctx.point,
            ctx.series_key,
            &evaluated.verdict,
            drift,
            CusumDriftRecordOptions {
                drift_escalate_after_secs: ctx.engine_config.drift_escalate_after_secs,
                severity_policy: ctx.severity_policy,
            },
        );
        candidates.push(EmissionCandidate::new(
            record,
            ctx.series_key.to_string(),
            ctx.metric_class.to_string(),
            transition,
            observed_at_unix_nano,
        ));
    }
}

/// Decode one feed frame's `MetricBatch`, score every eligible point, and push a
/// verdict telemetry batch for any breaches.
pub(crate) async fn process_frame(
    engine: &Arc<Mutex<DetectorEngine>>,
    verdict_tx: &broadcast::Sender<TelemetryBatch>,
    telemetry_drops: &NativeTelemetryDropCounters,
    scoring_health: &Arc<Mutex<ScoringHealth>>,
    frame: &MetricFeedFrame,
) {
    let batch = match MetricBatch::decode(frame.payload.as_slice()) {
        Ok(batch) => batch,
        Err(_) => return, // poison payload: drop the frame, never block the feed
    };
    let resource = batch.resource.unwrap_or_default();

    // Lock the engine only to score; never hold the std Mutex across an await.
    let mut scored_samples = 0_u64;
    let mut last_scored_at_unix_nano = 0_u64;
    let (mut records, shed_report, emission_shed_report, emitted_records) = {
        let mut engine = lock_engine(engine);
        let engine_config = engine.config();
        let dropped_before = engine.dropped_at_capacity;
        let mut shed_report: Option<ShedReport> = None;
        let mut candidates: Vec<EmissionCandidate> = Vec::new();
        for metric in &batch.metrics {
            if is_process_metric(metric) {
                // Process/PID series are excluded from anomaly centrally
                // (sample_extractor) and at the edge for the same reason.
                continue;
            }
            if engine.metric_denied(&metric.name) {
                continue;
            }

            // Monotonic cumulative counters (SNMP interface octets, etc.) cannot
            // be z-scored as raw values; rate-normalize each reading to a
            // per-second rate the same way central does before scoring.
            let counter = is_cumulative_counter(metric);
            let metric_class = metric_class(metric);
            let profile_class = metric_profile_class(metric, metric_class);
            if !engine.metric_class_enabled(profile_class) {
                continue;
            }

            // Per-series fidelity profile (dispersion floors + saturation gate).
            // A rate-normalized counter has NO saturation ceiling, so it stays
            // purely z-based (no gate) — a real flood must still fire. A
            // saturation gauge (cpu/mem/disk used_percent) gets the directional +
            // absolute-floor gate and the dispersion floors so a benign near-
            // constant level cannot explode into a Critical.
            let profile = if counter {
                counter_series_profile(metric)
            } else {
                series_profile_for(metric)
            };
            let profile = engine.apply_metric_class_override(profile_class, profile);
            let host_cpu_profile =
                engine.apply_metric_class_override(profile_class, host_cpu_aggregate_profile());
            let severity_policy = engine.severity_policy_for(profile_class);

            for point in &metric.points {
                if is_snmp_metric_class(metric_class)
                    && snmp_polled_device_identity(&resource, metric_class, metric, point)
                        .is_empty()
                {
                    continue;
                }

                let series_key = series_key_for(&resource, metric, point);
                // The seasonal baseline is delivered keyed by the canonical
                // device-uid + metric (central's `series:uid` profile keyspace),
                // NOT the fine detector `series_key`. Resolve it by that key so a
                // delivered hour-of-week baseline actually applies at the edge.
                let seasonal_key = seasonal_series_key(&resource, metric_class, metric, point);

                let value = if counter {
                    match engine.normalize_counter_with_max_rate(
                        &series_key,
                        counter_raw_value(point),
                        point.observed_at_unix_nano,
                        &counter_reset_anchor(point),
                        counter_width(metric, point),
                        max_counter_rate_per_second(metric, point),
                    ) {
                        Some(rate) => rate,
                        // Warmup / reset / gap / non-monotonic: no sample this point.
                        None => continue,
                    }
                } else {
                    point.value
                };

                scored_samples = scored_samples.saturating_add(1);
                last_scored_at_unix_nano =
                    last_scored_at_unix_nano.max(point.observed_at_unix_nano);

                if let Some(evaluated) = engine.evaluate_transition_with_seasonal_key(
                    &series_key,
                    &seasonal_key,
                    value,
                    point.observed_at_unix_nano,
                    profile,
                ) {
                    push_evaluated_candidates(
                        &mut candidates,
                        CandidateContext {
                            engine_config: &engine_config,
                            resource: &resource,
                            metric,
                            point,
                            series_key: &series_key,
                            metric_class,
                            profile,
                            severity_policy,
                        },
                        evaluated,
                    );
                }

                if let Some((host_metric, host_point, host_series_key, host_seasonal_key)) =
                    observe_host_cpu_aggregate(
                        &mut engine,
                        &resource,
                        metric_class,
                        metric,
                        point,
                        value,
                        host_cpu_profile,
                    )
                {
                    scored_samples = scored_samples.saturating_add(1);
                    last_scored_at_unix_nano =
                        last_scored_at_unix_nano.max(host_point.observed_at_unix_nano);

                    if let Some(evaluated) = engine.evaluate_transition_with_seasonal_key(
                        &host_series_key,
                        &host_seasonal_key,
                        host_point.value,
                        host_point.observed_at_unix_nano,
                        host_cpu_profile,
                    ) {
                        push_evaluated_candidates(
                            &mut candidates,
                            CandidateContext {
                                engine_config: &engine_config,
                                resource: &resource,
                                metric: &host_metric,
                                point: &host_point,
                                series_key: &host_series_key,
                                metric_class,
                                profile: host_cpu_profile,
                                severity_policy,
                            },
                            evaluated,
                        );
                    }
                }
            }
        }

        let dropped_after = engine.dropped_at_capacity;
        if dropped_after > dropped_before {
            shed_report = Some(ShedReport {
                dropped_delta: dropped_after - dropped_before,
                dropped_total: dropped_after,
                tracked_series: engine.series_count(),
                tracked_counters: engine.counter_count(),
                max_series: engine.max_series(),
            });
        }

        let detected_transitions = candidates.len() as u64;
        let mut accounting = EmissionAccounting::default();
        let compacted = compact_latest_by_series(candidates, &mut accounting);
        let mut cooldown_passed = Vec::with_capacity(compacted.len());
        for candidate in compacted {
            if engine.anomaly_emission_allowed(
                &candidate.series_key,
                candidate.transition,
                candidate.observed_at_unix_nano,
                engine_config.emission_cooldown_secs,
            ) {
                cooldown_passed.push(candidate);
            } else {
                accounting.account_cooldown(&candidate);
            }
        }

        let governed_non_clear = cooldown_passed
            .iter()
            .filter(|candidate| candidate.transition != AnomalyTransition::Clear)
            .count();
        let storm = engine
            .update_emission_storm(governed_non_clear, engine_config.emission_budget_per_tick);
        let selected = apply_emission_budget(
            cooldown_passed,
            engine_config.emission_budget_per_tick,
            &mut accounting,
        );
        let emitted_records = selected.len() as u64;

        for candidate in &selected {
            engine.mark_anomaly_emitted(
                &candidate.series_key,
                candidate.transition,
                candidate.observed_at_unix_nano,
            );
        }

        let emission_shed_report = accounting.into_report(
            detected_transitions,
            emitted_records,
            storm.active,
            storm.entered,
            storm.exited,
        );
        let records: Vec<TelemetryRecord> = selected
            .into_iter()
            .map(|candidate| candidate.record)
            .collect();
        (records, shed_report, emission_shed_report, emitted_records)
    };

    if let Some(report) = shed_report {
        records.push(shed_record(&resource, frame.feed_id, report));
    }
    if let Some(report) = emission_shed_report {
        records.push(emission_shed_record(&resource, frame.feed_id, report));
    }

    lock_scoring_health(scoring_health).record_frame(ScoringFrameUpdate {
        feed_id: frame.feed_id,
        scored_samples,
        emitted_verdicts: emitted_records,
        last_scored_at_unix_nano,
    });

    if records.is_empty() {
        return;
    }

    let mut builder = TelemetryBatchBuilder::new("anomaly-addon", resource.agent_id.clone());
    for record in records {
        builder = builder.push_record(record);
    }
    if verdict_tx.send(builder.build()).is_err() {
        telemetry_drops.record_no_subscriber_batch();
    }
}

fn observe_host_cpu_aggregate(
    engine: &mut DetectorEngine,
    resource: &addon_sdk::metric_pb::MetricResource,
    metric_class: &str,
    metric: &Metric,
    point: &MetricPoint,
    value: f64,
    host_profile: SeriesProfile,
) -> Option<(Metric, MetricPoint, String, String)> {
    if !matches!(gauge_class(metric), Some(GaugeClass::Cpu)) {
        return None;
    }

    let core_id = entry_value(&point.attributes, &["core_id"])
        .or_else(|| entry_value(&metric.tags, &["core_id"]))?;
    let host_metric = host_cpu_aggregate_metric(metric);
    let identity_point = MetricPoint::default();
    let host_series_key = series_key_for(resource, &host_metric, &identity_point);
    let saturation_gate = host_profile
        .saturation_gate
        .map_or(85.0, |gate| gate.min_value);
    let sample = engine.observe_host_cpu_core_sample(
        &host_series_key,
        core_id,
        value,
        point.observed_at_unix_nano,
        CPU_EVALUATION_INTERVAL_NS,
        saturation_gate,
    )?;
    let host_point = host_cpu_aggregate_point(sample);
    let host_seasonal_key = seasonal_series_key(resource, metric_class, &host_metric, &host_point);

    Some((host_metric, host_point, host_series_key, host_seasonal_key))
}

fn host_cpu_aggregate_metric(metric: &Metric) -> Metric {
    let mut host_metric = metric.clone();
    host_metric
        .tags
        .retain(|entry| entry.key != "core_id" && entry.key != "label");
    host_metric
}

fn host_cpu_aggregate_point(sample: HostCpuAggregateSample) -> MetricPoint {
    MetricPoint {
        value: sample.mean_value,
        observed_at_unix_nano: sample.observed_at_unix_nano,
        metadata: vec![
            string_entry("aggregation", "host_cpu_mean"),
            string_entry(
                "slot_start_unix_nano",
                &sample.slot_start_unix_nano.to_string(),
            ),
            string_entry("core_count", &sample.core_count.to_string()),
            string_entry("cores_above_gate", &sample.cores_above_gate.to_string()),
            string_entry(
                "cores_above_gate_fraction",
                &format!("{:.6}", sample.fraction_above_gate),
            ),
            string_entry("peak_value", &format!("{:.6}", sample.peak_value)),
            string_entry("peak_at_unix_nano", &sample.peak_at_unix_nano.to_string()),
        ],
        ..Default::default()
    }
}

fn string_entry(key: &str, value: &str) -> StringMapEntry {
    StringMapEntry {
        key: key.to_string(),
        value: value.to_string(),
    }
}

fn compact_latest_by_series(
    candidates: Vec<EmissionCandidate>,
    accounting: &mut EmissionAccounting,
) -> Vec<EmissionCandidate> {
    let mut groups: BTreeMap<String, Vec<EmissionCandidate>> = BTreeMap::new();
    for candidate in candidates {
        groups
            .entry(candidate.series_key.clone())
            .or_default()
            .push(candidate);
    }

    let mut compacted = Vec::new();
    for (_series_key, mut group) in groups {
        if group.len() == 1 {
            compacted.push(group.remove(0));
            continue;
        }

        let open_then_clear = group
            .first()
            .is_some_and(|candidate| candidate.transition == AnomalyTransition::Open)
            && group
                .last()
                .is_some_and(|candidate| candidate.transition == AnomalyTransition::Clear);

        if open_then_clear {
            for candidate in &group {
                accounting.account_compacted(candidate);
            }
            continue;
        }

        let keep_index = group.len() - 1;
        for (index, candidate) in group.into_iter().enumerate() {
            if index == keep_index {
                compacted.push(candidate);
            } else {
                accounting.account_compacted(&candidate);
            }
        }
    }

    compacted
}

fn apply_emission_budget(
    mut candidates: Vec<EmissionCandidate>,
    budget_per_tick: usize,
    accounting: &mut EmissionAccounting,
) -> Vec<EmissionCandidate> {
    let mut selected = Vec::new();
    let mut non_clear = Vec::new();

    for candidate in candidates.drain(..) {
        if candidate.transition == AnomalyTransition::Clear {
            selected.push(candidate);
        } else {
            non_clear.push(candidate);
        }
    }

    sort_candidates_for_budget(&mut non_clear);

    let budget = budget_per_tick.max(1);
    let open_reserve = ((budget * OPEN_RESERVE_PERCENT).div_ceil(100)).max(1);
    let mut selected_non_clear = HashSet::new();
    let mut remaining = budget;
    let mut reserved_opens = open_reserve.min(budget);

    for (index, candidate) in non_clear.iter().enumerate() {
        if remaining == 0 || reserved_opens == 0 {
            break;
        }
        if candidate.transition == AnomalyTransition::Open {
            selected_non_clear.insert(index);
            remaining -= 1;
            reserved_opens -= 1;
        }
    }

    for (index, _candidate) in non_clear.iter().enumerate() {
        if remaining == 0 {
            break;
        }
        if selected_non_clear.insert(index) {
            remaining -= 1;
        }
    }

    for (index, candidate) in non_clear.into_iter().enumerate() {
        if selected_non_clear.contains(&index) {
            selected.push(candidate);
        } else {
            accounting.account_budget(&candidate);
        }
    }

    selected
}

fn sort_candidates_for_budget(candidates: &mut [EmissionCandidate]) {
    candidates.sort_by(|left, right| {
        candidate_priority(left)
            .cmp(&candidate_priority(right))
            .then_with(|| right.severity_id.cmp(&left.severity_id))
            .then_with(|| left.observed_at_unix_nano.cmp(&right.observed_at_unix_nano))
            .then_with(|| left.series_key.cmp(&right.series_key))
    });
}

fn candidate_priority(candidate: &EmissionCandidate) -> u8 {
    match candidate.transition {
        AnomalyTransition::Clear => 0,
        AnomalyTransition::Open if candidate.severity_id >= 4 => 1,
        AnomalyTransition::Open => 2,
        AnomalyTransition::Update => 3,
        AnomalyTransition::None => 4,
    }
}

fn record_severity_id(record: &TelemetryRecord) -> i64 {
    serde_json::from_slice::<serde_json::Value>(&record.payload)
        .ok()
        .and_then(|event| event.get("severity_id").and_then(serde_json::Value::as_i64))
        .unwrap_or(0)
}

pub(crate) fn telemetry_stream_from_receiver(
    mut rx: broadcast::Receiver<TelemetryBatch>,
    telemetry_drops: Arc<NativeTelemetryDropCounters>,
) -> TelemetryStream {
    let (tx, out_rx) = mpsc::channel::<Result<TelemetryBatch, Status>>(VERDICT_CHANNEL_DEPTH);

    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(batch) => match tx.try_send(Ok(batch)) {
                    Ok(()) => {}
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        telemetry_drops.record_outbound_full_batch();
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => break,
                },
                Err(broadcast::error::RecvError::Lagged(count)) => {
                    telemetry_drops.record_lagged_batches(count);
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    Box::pin(ReceiverStream::new(out_rx))
}
