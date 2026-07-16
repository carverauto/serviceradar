// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Per-metric classification: process exclusion, cumulative-counter detection,
//! saturation-gauge classes, and the per-series fidelity [`SeriesProfile`].

use addon_sdk::metric_pb::{Metric, MetricKind, MetricPoint, MetricTemporality};
use serviceradar_anomaly_core::SaturationGate;

use crate::engine::{DriftMode, SeriesProfile};
use crate::identity::{metadata_f64_value, metadata_u32_value};

pub(crate) const CPU_EVALUATION_INTERVAL_NS: u64 = 30 * 1_000_000_000;

pub(crate) fn is_process_metric(metric: &Metric) -> bool {
    metric.metric_type == "process" || metric.name.starts_with("process.")
}

/// A cumulative-monotonic counter (SNMP interface octets/packets, etc.): a SUM
/// kind, cumulative temporality, monotonic. Mirrors central
/// `CounterNormalizer.cumulative_monotonic?` so the same series are rate-derived
/// at the edge and centrally. Such a metric's points are rate-normalized (not
/// dropped) before scoring.
pub(crate) fn is_cumulative_counter(metric: &Metric) -> bool {
    metric.is_monotonic
        && metric.temporality == MetricTemporality::Cumulative as i32
        && metric.kind == MetricKind::Sum as i32
}

/// The saturation-gauge class of a metric, derived from `metric_type` exactly as
/// central `series_config.metric_group/2` does (so edge and central agree on what
/// a gauge is). `None` means "not a saturation gauge" — the series stays purely
/// z-based with no dispersion floors (counters, interface rates, ICMP RTT, and
/// any unclassified metric). The class drives the fidelity defaults below.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum GaugeClass {
    Cpu,
    Mem,
    Disk,
}

/// Classify a metric's `metric_type` into a saturation-gauge class. Mirrors
/// central `metric_group/2`: `sysmon.cpu`/`cpu` -> CPU, `sysmon.memory`/`memory`
/// -> Mem, `sysmon.disk`/`disk` -> Disk. Everything else (snmp/icmp/flow/otel and
/// any unknown) is not a saturation gauge.
///
/// The `metric_type` match is necessary but NOT sufficient: the agent emits
/// non-percent series under these same types (e.g. `cpu.frequency_hz` /
/// `cpu.cluster.frequency_hz` are `sysmon.cpu`, unit Hz, ~GHz). Those are not
/// bounded 0-100% utilization gauges, so the directional saturation gate would
/// wrongly suppress a legitimate DOWNWARD excursion (CPU thermal throttling /
/// power-capping). We therefore additionally require the metric to be the
/// percent-utilization gauge — its `name` ends with `usage_percent` or
/// `used_percent` (matching `cpu.usage_percent`, `memory.used_percent`,
/// `disk.used_percent`). Frequency and any other non-percent series under these
/// types get `None` -> the default profile -> stay purely z-based (catching the
/// throttling excursion the symmetric z-score detects).
pub(crate) fn gauge_class(metric: &Metric) -> Option<GaugeClass> {
    if !is_utilization_percent_gauge(metric) {
        return None;
    }
    match metric.metric_type.as_str() {
        "sysmon.cpu" | "cpu" => Some(GaugeClass::Cpu),
        "sysmon.memory" | "memory" => Some(GaugeClass::Mem),
        "sysmon.disk" | "disk" => Some(GaugeClass::Disk),
        _ => None,
    }
}

/// True when the metric is the percent-utilization gauge of its group — its name
/// ends with `usage_percent` (cpu) or `used_percent` (mem/disk). This is the gate
/// that distinguishes a bounded 0-100% saturation gauge (`cpu.usage_percent`)
/// from a non-percent series riding the same `metric_type` (`cpu.frequency_hz`).
pub(crate) fn is_utilization_percent_gauge(metric: &Metric) -> bool {
    let name = metric.name.as_str();
    name.ends_with("usage_percent") || name.ends_with("used_percent")
}

/// Build the per-series fidelity [`SeriesProfile`] for a (non-counter) metric.
///
/// Saturation gauges (cpu/mem/disk `used_percent`) measure a bounded 0-100%
/// utilization with a meaningful direction: only *rising* utilization toward the
/// ceiling matters, and a low absolute value is benign no matter how the z-score
/// reads. So a gauge gets:
///   * a directional + absolute-floor saturation gate (fix #3) — only an upward
///     excursion ABOVE `min_breach_value` can breach; a benign low level (live:
///     disk 1.36%, mem 6.4%, a CPU core briefly at 18%) never alerts; and
///   * dispersion floors (fix #2) — `min_std_floor` in percentage points and a
///     relative `min_cv`, so a near-constant level with sub-point jitter cannot
///     manufacture a huge z-score.
///
/// Defaults are deliberately conservative (benign-suppressing, not alert-
/// suppressing): a disk genuinely climbing toward full, memory pressure, or a
/// CPU pinned high still clears the floor and fires. Per-core CPU is the most
/// volatile, so its floor is the highest (one core at 18%, or even a brief 100%
/// spike on a single core, must not page). These are the edge built-in defaults;
/// The control-plane `metric_classes` override may further raise those floors
/// and tune the class severity policy, but never weakens the safe defaults.
///
/// A non-gauge metric returns the default profile (no floors, no gate): purely
/// z-based, unchanged from prior behavior.
pub(crate) fn series_profile_for(metric: &Metric) -> SeriesProfile {
    match gauge_class(metric) {
        // Disk used_percent: very low variance normally; the live false-fire was
        // disk at ~1.36% with ~0.01 jitter. A 1-point absolute floor + 5% CV
        // tames the denominator; nothing under 80% full is worth a Critical.
        Some(GaugeClass::Disk) => SeriesProfile {
            min_std_floor: 1.0,
            min_cv: 0.05,
            abs_effect_floor: 0.0,
            saturation_gate: Some(SaturationGate {
                directional: true,
                min_value: 80.0,
            }),
            evaluation_interval_ns: None,
            drift_mode: DriftMode::Off,
            drift_min_cv: 0.0,
            spike_adopt_after_samples: None,
        },
        // Memory used_percent: commonly runs 60-80% benignly (caches, buffers).
        // Same dispersion floors; only sustained pressure above 80% breaches.
        Some(GaugeClass::Mem) => SeriesProfile {
            min_std_floor: 1.0,
            min_cv: 0.05,
            abs_effect_floor: 0.0,
            saturation_gate: Some(SaturationGate {
                directional: true,
                min_value: 80.0,
            }),
            evaluation_interval_ns: None,
            drift_mode: DriftMode::DeseasonalizedOnly,
            drift_min_cv: 0.0,
            spike_adopt_after_samples: None,
        },
        // CPU used_percent (per-core): the noisiest gauge — individual cores spike
        // to 100% constantly and benignly. A higher absolute floor + std/CV floor
        // keep one core at 18% (or a brief single-core spike) from paging; only a
        // core sustained at/above 85% breaches.
        Some(GaugeClass::Cpu) => SeriesProfile {
            min_std_floor: 5.0,
            min_cv: 0.10,
            abs_effect_floor: 0.0,
            saturation_gate: Some(SaturationGate {
                directional: true,
                min_value: 85.0,
            }),
            evaluation_interval_ns: Some(CPU_EVALUATION_INTERVAL_NS),
            drift_mode: DriftMode::DeseasonalizedOnly,
            drift_min_cv: 0.0,
            spike_adopt_after_samples: None,
        },
        None => SeriesProfile::default(),
    }
}

pub(crate) fn metric_profile_class(metric: &Metric, metric_class: &str) -> &'static str {
    match gauge_class(metric) {
        Some(GaugeClass::Cpu) => "cpu",
        Some(GaugeClass::Mem) => "memory",
        Some(GaugeClass::Disk) => "disk",
        None if metric_class == "snmp" || metric_class.starts_with("snmp.") => "interface",
        None if metric_class == "icmp" || metric_class.starts_with("icmp.") => "icmp",
        None => "other",
    }
}

const INTERFACE_PACKET_STD_FLOOR: f64 = 30.0;
const INTERFACE_PACKET_ABS_EFFECT_FLOOR: f64 = 100.0;
const INTERFACE_BYTE_STD_FLOOR: f64 = 32.0 * 1024.0;
const INTERFACE_BYTE_ABS_EFFECT_FLOOR: f64 = 128.0 * 1024.0;

/// Rate-normalized interface counters are the class most exposed to diurnal
/// baseline lock-in. Packet and byte rates use different physical units, so the
/// floors must be family-specific rather than a single magic number.
pub(crate) fn counter_series_profile(metric: &Metric) -> SeriesProfile {
    let name = metric.name.to_ascii_lowercase();
    let packet_rate = name.contains("pkt") || name.contains("packet");
    let byte_rate = name.contains("octet") || name.contains("byte");

    // Dispersion/effect floors are meaningful for traffic *rates* only. Applying
    // the byte-rate floor to every non-packet SNMP counter would blind error,
    // discard, and retransmission counters whose useful rates are often small.
    let (min_std_floor, abs_effect_floor) = if packet_rate {
        (
            INTERFACE_PACKET_STD_FLOOR,
            INTERFACE_PACKET_ABS_EFFECT_FLOOR,
        )
    } else if byte_rate {
        (INTERFACE_BYTE_STD_FLOOR, INTERFACE_BYTE_ABS_EFFECT_FLOOR)
    } else {
        return SeriesProfile {
            // Error/discard/retransmission counters are not traffic bytes or
            // packets, but they still need deseasonalized drift coverage.
            drift_mode: DriftMode::DeseasonalizedOnly,
            drift_min_cv: 0.05,
            spike_adopt_after_samples: Some(300),
            ..SeriesProfile::default()
        };
    };

    SeriesProfile {
        min_std_floor,
        min_cv: 0.20,
        abs_effect_floor,
        drift_mode: DriftMode::DeseasonalizedOnly,
        drift_min_cv: 0.05,
        spike_adopt_after_samples: Some(300),
        ..SeriesProfile::default()
    }
}

pub(crate) fn host_cpu_aggregate_profile() -> SeriesProfile {
    SeriesProfile {
        min_std_floor: 5.0,
        min_cv: 0.10,
        abs_effect_floor: 0.0,
        saturation_gate: Some(SaturationGate {
            directional: true,
            min_value: 85.0,
        }),
        evaluation_interval_ns: None,
        drift_mode: DriftMode::DeseasonalizedOnly,
        drift_min_cv: 0.0,
        spike_adopt_after_samples: None,
    }
}

/// The authoritative counter reading: the typed `raw_value` (the uint string SNMP
/// carries) when present, else the float `value`. Central prefers `raw_value`
/// for the same reason — the float can lose precision on a large u64.
pub(crate) fn counter_raw_value(point: &MetricPoint) -> f64 {
    let raw = point.raw_value.trim();
    if !raw.is_empty()
        && let Ok(parsed) = raw.parse::<f64>()
    {
        return parsed;
    }

    point.value
}

/// The reset-lineage anchor: the counter's start time when set, else the explicit
/// reset anchor. A change between readings means the counter restarted, so a rate
/// across it is dropped. Mirrors central's `reset_anchor` preference order.
pub(crate) fn counter_reset_anchor(point: &MetricPoint) -> String {
    if point.start_time_unix_nano > 0 {
        point.start_time_unix_nano.to_string()
    } else {
        point.reset_anchor.clone()
    }
}

/// Counter width can arrive as the typed metric field or as legacy metadata keys.
/// Preserve central's old metadata fallback so a zero proto field does not
/// silently suppress otherwise-corroborated 32-bit wrap handling.
pub(crate) fn counter_width(metric: &Metric, point: &MetricPoint) -> u32 {
    if metric.counter_width > 0 {
        return metric.counter_width;
    }

    metadata_u32_value(point, &["counter_width", "counter_bits", "pdu_width"])
        .or_else(|| metadata_u32_value(metric, &["counter_width", "counter_bits", "pdu_width"]))
        .unwrap_or(0)
}

pub(crate) fn max_counter_rate_per_second(metric: &Metric, point: &MetricPoint) -> Option<f64> {
    metadata_f64_value(point, &["max_counter_rate_per_second"])
        .or_else(|| metadata_f64_value(metric, &["max_counter_rate_per_second"]))
        .filter(|rate| rate.is_finite() && *rate > 0.0)
}
