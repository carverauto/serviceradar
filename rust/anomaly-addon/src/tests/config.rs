// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::Addon;
use addon_sdk::metric_pb::Metric;

use crate::AnomalyAddon;
use crate::checkpoint::{resolve_checkpoint_settings, resolve_scoring_stale_after_ns};
use crate::config::{AddonConfig, DEFAULT_SCORING_STALE_AFTER_NS};
use crate::engine::{BurstEnvelope, DetectorEngine, DriftMode, EngineConfig, SeriesProfile};
use crate::metrics_classify::counter_series_profile;

#[test]
fn config_empty_optional_numbers_fall_back_to_defaults() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "window_size": "",
        "min_samples": "",
        "n_sigma": "",
        "confirm_slots": "",
        "max_series": "",
        "min_std_floor": "",
        "min_cv": "",
        "checkpoint_max_age_secs": "",
        "scoring_stale_after_secs": ""
    }))
    .expect("empty strings should deserialize as unset optional knobs");

    let base = EngineConfig::default();
    assert_eq!(
        resolve_scoring_stale_after_ns(&config),
        DEFAULT_SCORING_STALE_AFTER_NS
    );

    let resolved = config.into_engine_config().expect("default config");
    assert_eq!(resolved.window_size, base.window_size);
    assert_eq!(resolved.min_samples, base.min_samples);
    assert_eq!(resolved.n_sigma, base.n_sigma);
    assert_eq!(resolved.confirm_slots, base.confirm_slots);
    assert_eq!(resolved.max_series, base.max_series);
    assert_eq!(resolved.min_std_floor, None);
    assert_eq!(resolved.min_cv, None);
    assert_eq!(resolved.metric_denylist, vec!["cpu.frequency_hz"]);
}

#[test]
fn config_accepts_numeric_strings_for_optional_numbers() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "window_size": "42",
        "min_samples": "7",
        "n_sigma": "2.5",
        "confirm_slots": "3",
        "max_series": "1234",
        "min_std_floor": "0.25",
        "min_cv": "0.10",
        "checkpoint_max_age_secs": "60",
        "scoring_stale_after_secs": "42"
    }))
    .expect("numeric strings should deserialize");

    let checkpoint = resolve_checkpoint_settings(&config);
    assert_eq!(checkpoint.max_age_ns, 60_000_000_000);
    assert_eq!(resolve_scoring_stale_after_ns(&config), 42_000_000_000);

    let resolved = config.into_engine_config().expect("valid config");
    assert_eq!(resolved.window_size, 42);
    assert_eq!(resolved.min_samples, 7);
    assert_eq!(resolved.n_sigma, 2.5);
    assert_eq!(resolved.confirm_slots, 3);
    assert_eq!(resolved.max_series, 1234);
    assert_eq!(resolved.min_std_floor, Some(0.25));
    assert_eq!(resolved.min_cv, Some(0.10));
    assert_eq!(resolved.metric_denylist, vec!["cpu.frequency_hz"]);
}

#[test]
fn config_applies_managed_defaults_below_operator_explicit_params() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "managed": {
            "window_size": 600,
            "min_samples": 60,
            "n_sigma": 4.0,
            "confirm_slots": 8,
            "metric_denylist": ["managed.metric", " managed.metric ", ""],
            "emission": {
                "cooldown_secs": 120,
                "budget_per_tick": 25,
                "episode_update_interval_secs": 900,
                "reopen_cooldown_secs": 300
            },
            "metric_classes": {
                "interface": {
                    "drift_mode": "deseasonalized_only",
                    "drift_min_effect": 2.5
                }
            }
        },
        "n_sigma": 5.5,
        "confirm_slots": 3
    }))
    .expect("managed projected config deserializes");

    assert_eq!(config.metric_class_override_count(), 1);

    let resolved = config.into_engine_config().expect("valid config");
    assert_eq!(resolved.window_size, 600);
    assert_eq!(resolved.min_samples, 60);
    assert_eq!(
        resolved.n_sigma, 5.5,
        "operator-explicit top-level value wins over managed"
    );
    assert_eq!(
        resolved.confirm_slots, 3,
        "operator-explicit top-level value wins over managed"
    );
    assert_eq!(resolved.emission_cooldown_secs, 120);
    assert_eq!(resolved.emission_budget_per_tick, 25);
    assert_eq!(resolved.episode_update_interval_secs, 900);
    assert_eq!(resolved.reopen_cooldown_secs, 300);
    assert_eq!(resolved.metric_denylist, vec!["managed.metric"]);
    assert_eq!(
        resolved
            .metric_class_overrides
            .get("interface")
            .and_then(|class_override| class_override.drift_mode),
        Some(DriftMode::DeseasonalizedOnly)
    );
}

#[test]
fn config_operator_explicit_emission_and_denylist_win_over_managed() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "managed": {
            "metric_denylist": ["managed.metric"],
            "emission": {
                "cooldown_secs": 120,
                "budget_per_tick": 25,
                "episode_update_interval_secs": 900,
                "reopen_cooldown_secs": 300
            }
        },
        "metric_denylist": [],
        "emission_cooldown_secs": 45,
        "emission_budget_per_tick": 7,
        "emission": {
            "cooldown_secs": 30,
            "budget_per_tick": 5
        }
    }))
    .expect("managed projected config deserializes");

    let resolved = config.into_engine_config().expect("valid config");
    assert_eq!(resolved.emission_cooldown_secs, 30);
    assert_eq!(resolved.emission_budget_per_tick, 5);
    assert_eq!(resolved.episode_update_interval_secs, 900);
    assert_eq!(resolved.reopen_cooldown_secs, 300);
    assert!(resolved.metric_denylist.is_empty());
}

#[test]
fn config_defaults_cusum_thresholds() {
    // Operator omits CUSUM knobs entirely: per-class drift_mode decides where
    // sustained-drift detection can run.
    let config: AddonConfig =
        serde_json::from_value(serde_json::json!({ "window_size": 100 })).expect("config");
    let resolved = config.into_engine_config().expect("default config");
    assert_eq!(resolved.cusum_k, 0.5);
    assert_eq!(resolved.cusum_h, 8.0);
    assert_eq!(resolved.h_confirm_mult, 1.5);
    assert_eq!(resolved.drift_confirm_window, 30);
    assert_eq!(resolved.drift_min_effect, 2.0);
    assert_eq!(resolved.drift_clear_slots, 30);
    assert_eq!(resolved.drift_adopt_after_samples, 600);
    assert_eq!(resolved.spike_adopt_after_samples, 600);
    assert_eq!(resolved.episode_update_interval_secs, 1_800);
    assert_eq!(resolved.reopen_cooldown_secs, 600);
    assert_eq!(resolved.anchor_max_age_secs, 86_400);
    assert_eq!(resolved.critical_min_duration_secs, 600);
    assert_eq!(resolved.drift_escalate_after_secs, 3_600);
    assert_eq!(resolved.emission_cooldown_secs, 300);
    assert_eq!(resolved.emission_budget_per_tick, 100);
    assert_eq!(resolved.metric_denylist, vec!["cpu.frequency_hz"]);
}

#[test]
fn config_wires_interface_spike_and_severity_overrides_into_the_engine() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "metric_classes": {
            "interface": {
                "spike_adopt_after_samples": 300,
                "abs_effect_floor": 1_000.0,
                "severity_cap": "medium",
                "severity_bands": {"medium": 2.0, "high": 4.0}
            }
        }
    }))
    .expect("interface config");

    let resolved = config.into_engine_config().expect("valid config");
    let interface = resolved
        .metric_class_overrides
        .get("interface")
        .expect("interface override");

    assert_eq!(interface.spike_adopt_after_samples, Some(300));
    assert_eq!(interface.abs_effect_floor, Some(1_000.0));
    assert_eq!(interface.severity_policy.cap, Some(3));
    assert_eq!(interface.severity_policy.bands(), (2.0, 4.0));
}

#[test]
fn config_wires_burst_envelope_overrides_into_the_engine() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "metric_classes": {
            "interface": {
                "burst_envelope_multiplier": 1.5,
                "burst_envelope_quantile": "0.95",
                "burst_envelope_lag_samples": 12,
                "burst_envelope_min_samples": "40"
            },
            "cpu": {"burst_envelope_enabled": true},
            "memory": {"burst_envelope_enabled": false}
        }
    }))
    .expect("burst envelope config");

    let resolved = config.into_engine_config().expect("valid config");
    let interface = resolved
        .metric_class_overrides
        .get("interface")
        .expect("interface override");
    assert_eq!(interface.burst_envelope_enabled, None);
    assert_eq!(interface.burst_envelope_multiplier, Some(1.5));
    assert_eq!(interface.burst_envelope_quantile, Some(0.95));
    assert_eq!(interface.burst_envelope_lag_samples, Some(12));
    assert_eq!(interface.burst_envelope_min_samples, Some(40));
    assert_eq!(
        resolved.metric_class_overrides["cpu"].burst_envelope_enabled,
        Some(true)
    );
    assert_eq!(
        resolved.metric_class_overrides["memory"].burst_envelope_enabled,
        Some(false)
    );

    // Applied to profiles: interface rates start with the default envelope and
    // take the tuned knobs; cpu gains the default envelope; memory loses it.
    let engine = DetectorEngine::new(resolved);
    let octets = Metric {
        name: "ifHCInOctets".to_string(),
        metric_type: "snmp.interface".to_string(),
        ..Default::default()
    };
    let interface_profile =
        engine.apply_metric_class_override("interface", counter_series_profile(&octets));
    let envelope = interface_profile
        .burst_envelope
        .expect("interface rates keep their envelope");
    assert_eq!(envelope.multiplier, 1.5);
    assert_eq!(envelope.quantile, 0.95);
    assert_eq!(envelope.lag_samples, 12);
    assert_eq!(envelope.min_samples, 40);

    let cpu_profile = engine.apply_metric_class_override("cpu", SeriesProfile::default());
    assert_eq!(cpu_profile.burst_envelope, Some(BurstEnvelope::default()));

    let memory_profile = engine.apply_metric_class_override(
        "memory",
        SeriesProfile {
            burst_envelope: Some(BurstEnvelope::default()),
            ..SeriesProfile::default()
        },
    );
    assert_eq!(memory_profile.burst_envelope, None);
}

#[test]
fn config_accepts_cusum_overrides_and_ignores_legacy_toggle() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "cusum_enabled": true,
        "cusum_k": "0.75",
        "cusum_h": 8.0,
        "h_confirm_mult": "1.25",
        "drift_confirm_window": "12",
        "drift_min_effect": "1.25",
        "drift_clear_slots": "7",
        "drift_adopt_after_samples": "90",
        "episode_update_interval_secs": "300",
        "reopen_cooldown_secs": "120",
        "anchor_max_age_secs": "240",
        "critical_min_duration_secs": "60",
        "drift_escalate_after_secs": "900",
        "emission_cooldown_secs": "45",
        "emission_budget_per_tick": "7"
    }))
    .expect("cusum config deserializes (ignored stale bool + string/number knobs)");

    let resolved = config.into_engine_config().expect("valid config");
    assert_eq!(resolved.cusum_k, 0.75);
    assert_eq!(resolved.cusum_h, 8.0);
    assert_eq!(resolved.h_confirm_mult, 1.25);
    assert_eq!(resolved.drift_confirm_window, 12);
    assert_eq!(resolved.drift_min_effect, 1.25);
    assert_eq!(resolved.drift_clear_slots, 7);
    assert_eq!(resolved.drift_adopt_after_samples, 90);
    assert_eq!(resolved.episode_update_interval_secs, 300);
    assert_eq!(resolved.reopen_cooldown_secs, 120);
    assert_eq!(resolved.anchor_max_age_secs, 240);
    assert_eq!(resolved.critical_min_duration_secs, 60);
    assert_eq!(resolved.drift_escalate_after_secs, 900);
    assert_eq!(resolved.emission_cooldown_secs, 45);
    assert_eq!(resolved.emission_budget_per_tick, 7);
}

#[test]
fn config_accepts_metric_denylist_override() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "metric_denylist": ["cpu.frequency_hz", "  ", "custom.metric", "custom.metric"]
    }))
    .expect("metric denylist config deserializes");

    let resolved = config.into_engine_config().expect("valid config");
    assert_eq!(
        resolved.metric_denylist,
        vec!["cpu.frequency_hz".to_string(), "custom.metric".to_string()]
    );

    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "metric_denylist": []
    }))
    .expect("empty metric denylist config deserializes");

    let resolved = config.into_engine_config().expect("valid config");
    assert!(resolved.metric_denylist.is_empty());
}

#[test]
fn config_accepts_additive_nested_profile_sections() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "emission_cooldown_secs": 999,
        "emission_budget_per_tick": 999,
        "episode_update_interval_secs": 999,
        "reopen_cooldown_secs": 999,
        "emission": {
            "cooldown_secs": 45,
            "budget_per_tick": 7,
            "episode_update_interval_secs": 300,
            "reopen_cooldown_secs": 120
        },
        "metric_classes": {
            "cpu": {
                "enabled": true,
                "drift_mode": "deseasonalized_only",
                "min_std_floor": "5.0",
                "severity_cap": "high"
            },
            "interface": {
                "drift_mode": "deseasonalized_only",
                "drift_min_effect": "2.5",
                "drift_min_cv": "0.15"
            }
        },
        "seasonal": {
            "max_baselines": 1
        },
        "seasonal_baselines": {
            "b-series": {
                "buckets": [
                    {"dow": 1, "hod": 9, "center": 70.0, "scale": 3.0, "sample_count": 8}
                ]
            },
            "a-series": {
                "buckets": [
                    {"dow": 1, "hod": 10, "center": 60.0, "scale": 2.0, "sample_count": 8}
                ]
            }
        }
    }))
    .expect("nested projected config deserializes");

    assert_eq!(config.metric_class_override_count(), 2);
    let baselines = config.resolve_seasonal_baselines();
    assert_eq!(baselines.len(), 1);
    assert!(
        baselines.contains_key("a-series"),
        "seasonal.max_baselines caps deterministically by sorted key"
    );

    let resolved = config.into_engine_config().expect("valid config");
    assert_eq!(resolved.emission_cooldown_secs, 45);
    assert_eq!(resolved.emission_budget_per_tick, 7);
    assert_eq!(resolved.episode_update_interval_secs, 300);
    assert_eq!(resolved.reopen_cooldown_secs, 120);
    let cpu = resolved
        .metric_class_overrides
        .get("cpu")
        .expect("cpu class override");
    assert_eq!(cpu.enabled, Some(true));
    assert_eq!(cpu.drift_mode, Some(DriftMode::DeseasonalizedOnly));
    assert_eq!(cpu.min_std_floor, Some(5.0));
    let interface = resolved
        .metric_class_overrides
        .get("interface")
        .expect("interface class override");
    assert_eq!(interface.drift_mode, Some(DriftMode::DeseasonalizedOnly));
    assert_eq!(interface.drift_min_cv, Some(0.15));
}

#[test]
fn config_top_level_metric_classes_win_over_managed() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "managed": {
            "metric_classes": {
                "cpu": {
                    "enabled": true,
                    "drift_mode": "deseasonalized_only",
                    "min_std_floor": 5.0
                }
            }
        },
        "metric_classes": {
            "CPU": {
                "enabled": false,
                "drift_mode": "off",
                "min_std_floor": 10.0
            }
        }
    }))
    .expect("metric class config deserializes");

    let resolved = config.into_engine_config().expect("valid config");
    assert_eq!(resolved.metric_class_overrides.len(), 1);
    let cpu = resolved
        .metric_class_overrides
        .get("cpu")
        .expect("normalized top-level cpu override");
    assert_eq!(cpu.enabled, Some(false));
    assert_eq!(cpu.drift_mode, Some(DriftMode::Off));
    assert_eq!(cpu.min_std_floor, Some(10.0));
}

#[test]
fn config_compat_old_flat_profile_and_new_nested_profile() {
    let old_profile = serde_json::json!({
        "window_size": 42,
        "min_samples": 7,
        "cusum_enabled": true,
        "emission_cooldown_secs": 15,
        "metric_denylist": ["cpu.frequency_hz"]
    });
    let config: AddonConfig =
        serde_json::from_value(old_profile).expect("old flat profile parses in new addon");
    let resolved = config.into_engine_config().expect("valid old profile");
    assert_eq!(resolved.window_size, 42);
    assert_eq!(resolved.min_samples, 7);
    assert_eq!(resolved.emission_cooldown_secs, 15);

    #[derive(Debug, serde::Deserialize)]
    struct LegacyAddonConfig {
        window_size: Option<usize>,
        cusum_enabled: Option<bool>,
        emission_cooldown_secs: Option<u64>,
        metric_denylist: Option<Vec<String>>,
    }

    let new_profile = serde_json::json!({
        "window_size": 100,
        "emission_cooldown_secs": 300,
        "metric_denylist": ["cpu.frequency_hz"],
        "emission": {
            "cooldown_secs": 45,
            "budget_per_tick": 7
        },
        "metric_classes": {
            "cpu": {
                "enabled": true,
                "drift_mode": "deseasonalized_only"
            }
        },
        "seasonal": {
            "max_baselines": 100
        }
    });
    let legacy: LegacyAddonConfig =
        serde_json::from_value(new_profile).expect("legacy parser ignores additive sections");
    assert_eq!(legacy.window_size, Some(100));
    assert_eq!(legacy.cusum_enabled, None);
    assert_eq!(legacy.emission_cooldown_secs, Some(300));
    assert_eq!(
        legacy.metric_denylist,
        Some(vec!["cpu.frequency_hz".to_string()])
    );
}

#[test]
fn config_rejects_min_samples_larger_than_window_size() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "window_size": 5,
        "min_samples": 6
    }))
    .expect("shape is valid");

    let err = config
        .into_engine_config()
        .expect_err("must reject cold window");
    assert!(err.contains("min_samples (6)"));
    assert!(err.contains("window_size (5)"));
}

#[test]
fn config_resolves_delivered_seasonal_baselines() {
    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "seasonal": {"min_bucket_samples": 7},
        "seasonal_baselines": {
            "series-a": {
                "buckets": [
                    {"dow": 1, "hod": 9, "center": 70.0, "scale": 3.0, "sample_count": 8},
                    {"dow": 9, "hod": 9, "center": 1.0, "scale": 1.0, "sample_count": 8},
                    {"dow": 2, "hod": 30, "center": 1.0, "scale": 1.0, "sample_count": 8}
                ]
            }
        }
    }))
    .expect("seasonal baselines deserialize");

    assert_eq!(config.resolve_seasonal_settings().min_bucket_samples, 7);

    let resolved = config.resolve_seasonal_baselines();
    assert_eq!(resolved.len(), 1);
    let profile = resolved
        .get("series-a")
        .expect("series-a baseline resolves");
    // Only the in-range (dow 1, hod 9) bucket survives; dow 9 and hod 30 are dropped.
    assert_eq!(profile.populated_bucket_count(), 1);
}

#[test]
fn config_resolves_compact_delivered_seasonal_baselines() {
    let mut centers = vec![serde_json::json!(100.0); serviceradar_anomaly_core::HOURS_PER_WEEK];
    let scales = vec![serde_json::json!(1.25); serviceradar_anomaly_core::HOURS_PER_WEEK];
    let sample_counts = vec![serde_json::json!(9); serviceradar_anomaly_core::HOURS_PER_WEEK];
    // Unix epoch is Thursday 00:00 UTC (dow=4, hod=0), deliberately not the
    // final/latest profile slot. This pins end-to-end resolution of a historic
    // bucket from the compact 168-element payload shape core delivers.
    let index = 4 * 24;
    centers[index] = serde_json::json!(42.5);

    let config: AddonConfig = serde_json::from_value(serde_json::json!({
        "seasonal_baselines": {
            "series-a": {
                "encoding": "compact_168_f32",
                "centers": centers,
                "scales": scales,
                "sample_counts": sample_counts
            }
        }
    }))
    .expect("compact seasonal baselines deserialize");

    let resolved = config.resolve_seasonal_baselines();
    let profile = resolved
        .get("series-a")
        .expect("series-a compact baseline resolves");
    assert_eq!(profile.populated_bucket_count(), 168);

    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.set_seasonal_settings(config.resolve_seasonal_settings());
    engine.set_seasonal_baselines(resolved);
    let verdict = engine
        .evaluate_with_seasonal_key(
            "detector-series-a",
            "series-a",
            42.5,
            0,
            SeriesProfile::default(),
        )
        .expect("non-latest seasonal bucket verdict");
    let seasonal = verdict
        .signals
        .iter()
        .find(|signal| signal.name == "seasonal")
        .expect("compact profile must resolve a seasonal signal");
    assert!(seasonal.ready);
    assert_eq!(seasonal.mean, Some(42.5));
    assert!(!seasonal.breached);
}

#[test]
fn config_without_seasonal_baselines_resolves_empty() {
    let config: AddonConfig =
        serde_json::from_value(serde_json::json!({ "window_size": 100 })).expect("config");
    assert!(
        config.resolve_seasonal_baselines().is_empty(),
        "no delivered baselines -> rolling-only (back-compat)"
    );
}

#[tokio::test]
async fn configure_accepts_delivered_seasonal_baselines() {
    let addon = AnomalyAddon::new();

    let result = addon
        .configure(
            br#"{"seasonal_baselines":{"s":{"buckets":[{"dow":1,"hod":9,"center":70.0,"scale":3.0,"sample_count":8}]}}}"#,
        )
        .await
        .expect("configure returns result");

    assert!(
        result.accepted,
        "configure must accept delivered baselines: {}",
        result.error
    );
}

#[tokio::test]
async fn configure_rejects_min_samples_larger_than_window_size() {
    let addon = AnomalyAddon::new();

    let result = addon
        .configure(br#"{"window_size":5,"min_samples":6}"#)
        .await
        .expect("configure returns result");

    assert!(!result.accepted);
    assert!(
        result
            .error
            .contains("min_samples (6) must be less than or equal to window_size (5)")
    );
}
