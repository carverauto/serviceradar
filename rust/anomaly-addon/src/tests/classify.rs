// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use super::support::{metric_named, metric_of_type};
use crate::engine::DriftMode;
use crate::metrics_classify::{
    GaugeClass, counter_series_profile, gauge_class, series_profile_for,
};

#[test]
fn gauge_classes_map_like_central_metric_group() {
    assert_eq!(
        gauge_class(&metric_of_type("sysmon.cpu")),
        Some(GaugeClass::Cpu)
    );
    assert_eq!(gauge_class(&metric_of_type("cpu")), Some(GaugeClass::Cpu));
    assert_eq!(
        gauge_class(&metric_of_type("sysmon.memory")),
        Some(GaugeClass::Mem)
    );
    assert_eq!(
        gauge_class(&metric_of_type("memory")),
        Some(GaugeClass::Mem)
    );
    assert_eq!(
        gauge_class(&metric_of_type("sysmon.disk")),
        Some(GaugeClass::Disk)
    );
    assert_eq!(gauge_class(&metric_of_type("disk")), Some(GaugeClass::Disk));
    // Non-gauges (snmp interface, icmp, flow, otel, unknown) are not gated.
    assert_eq!(gauge_class(&metric_of_type("snmp")), None);
    assert_eq!(gauge_class(&metric_of_type("icmp")), None);
    assert_eq!(gauge_class(&metric_of_type("flow")), None);
    assert_eq!(gauge_class(&metric_of_type("otel.metric_point")), None);
    assert_eq!(gauge_class(&metric_of_type("")), None);
}

#[test]
fn gauge_profile_carries_directional_floor_gate() {
    // Disk/mem get the 80% floor; cpu gets the relaxed 85% floor. All are
    // directional, and all carry a nonzero dispersion floor.
    for (ty, floor) in [
        ("sysmon.disk", 80.0),
        ("sysmon.memory", 80.0),
        ("sysmon.cpu", 85.0),
    ] {
        let profile = series_profile_for(&metric_of_type(ty));
        let gate = profile.saturation_gate.expect("gauge must have a gate");
        assert!(gate.directional, "{ty} gate must be directional");
        assert_eq!(gate.min_value, floor, "{ty} absolute floor");
        assert!(profile.min_std_floor > 0.0, "{ty} must have a std floor");
        assert!(profile.min_cv > 0.0, "{ty} must have a cv floor");
        if ty == "sysmon.disk" {
            assert_eq!(profile.drift_mode, DriftMode::Off);
        } else {
            assert_eq!(profile.drift_mode, DriftMode::DeseasonalizedOnly);
        }
    }
}

#[test]
fn non_gauge_metric_gets_default_profile() {
    // An SNMP interface metric stays purely z-based (no gate, no floors).
    let profile = series_profile_for(&metric_of_type("snmp"));
    assert!(profile.saturation_gate.is_none());
    assert_eq!(profile.min_std_floor, 0.0);
    assert_eq!(profile.min_cv, 0.0);
    assert_eq!(profile.drift_mode, DriftMode::Off);
}

#[test]
fn counter_profile_is_deseasonalized_only_with_scoring_floors() {
    let profile = counter_series_profile(&metric_named("ifOutUcastPkts", "snmp"));
    assert!(profile.saturation_gate.is_none());
    assert!(profile.min_std_floor > 0.0);
    assert!(profile.min_cv > 0.0);
    assert!(profile.abs_effect_floor > 0.0);
    assert_eq!(profile.spike_adopt_after_samples, Some(300));
    assert_eq!(profile.drift_mode, DriftMode::DeseasonalizedOnly);
    assert_eq!(profile.drift_min_cv, 0.05);
}

#[test]
fn counter_profile_uses_a_larger_byte_rate_floor() {
    let packets = counter_series_profile(&metric_named("ifInUcastPkts", "snmp"));
    let bytes = counter_series_profile(&metric_named("ifInOctets", "snmp"));

    assert!(bytes.min_std_floor > packets.min_std_floor);
    assert!(bytes.abs_effect_floor > packets.abs_effect_floor);
}

#[test]
fn counter_profile_keeps_error_and_discard_rates_sensitive() {
    for name in ["ifInErrors", "ifOutDiscards", "tcpRetransSegs"] {
        let profile = counter_series_profile(&metric_named(name, "snmp"));
        assert_eq!(profile.min_std_floor, 0.0, "{name}");
        assert_eq!(profile.min_cv, 0.0, "{name}");
        assert_eq!(profile.abs_effect_floor, 0.0, "{name}");
        assert_eq!(profile.drift_mode, DriftMode::DeseasonalizedOnly, "{name}");
        assert!(profile.drift_min_cv > 0.0, "{name}");
    }
}

#[test]
fn cpu_frequency_under_sysmon_cpu_is_not_a_saturation_gauge() {
    // The agent emits `cpu.frequency_hz` / `cpu.cluster.frequency_hz` under
    // metric_type `sysmon.cpu` (unit Hz, ~GHz) — NOT a 0-100% utilization
    // gauge. The directional saturation gate would suppress a downward
    // frequency excursion (CPU thermal throttling / power-capping), a real
    // anomaly the symmetric z-score catches. So these must fall to the default
    // profile (no gate, no floors), staying purely z-based.
    for name in ["cpu.frequency_hz", "cpu.cluster.frequency_hz"] {
        let metric = metric_named(name, "sysmon.cpu");
        assert_eq!(
            gauge_class(&metric),
            None,
            "{name} must not be classified as a saturation gauge"
        );
        let profile = series_profile_for(&metric);
        assert!(
            profile.saturation_gate.is_none(),
            "{name} must have no saturation gate (allows downward throttling)"
        );
        assert_eq!(profile.min_std_floor, 0.0, "{name} must have no std floor");
        assert_eq!(profile.min_cv, 0.0, "{name} must have no cv floor");
    }
}

#[test]
fn percent_utilization_gauges_keep_their_saturation_gate() {
    // The percent gauges the agent actually emits stay gated exactly as
    // before: cpu.usage_percent (Cpu, 85% floor), memory.used_percent (Mem,
    // 80%), disk.used_percent (Disk, 80%). The gate is what suppresses benign
    // low values; only the percent gauge gets it.
    for (name, ty, floor) in [
        ("cpu.usage_percent", "sysmon.cpu", 85.0),
        ("memory.used_percent", "sysmon.memory", 80.0),
        ("disk.used_percent", "sysmon.disk", 80.0),
    ] {
        let metric = metric_named(name, ty);
        assert!(
            gauge_class(&metric).is_some(),
            "{name} must remain a saturation gauge"
        );
        let profile = series_profile_for(&metric);
        let gate = profile
            .saturation_gate
            .unwrap_or_else(|| panic!("{name} must keep its saturation gate"));
        assert!(gate.directional, "{name} gate must be directional");
        assert_eq!(gate.min_value, floor, "{name} absolute floor");
        assert!(profile.min_std_floor > 0.0, "{name} must keep a std floor");
        assert!(profile.min_cv > 0.0, "{name} must keep a cv floor");
    }
}
