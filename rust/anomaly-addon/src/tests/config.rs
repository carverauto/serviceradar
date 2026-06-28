// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::Addon;

use crate::AnomalyAddon;
use crate::checkpoint::{resolve_checkpoint_settings, resolve_scoring_stale_after_ns};
use crate::config::{AddonConfig, DEFAULT_SCORING_STALE_AFTER_NS};
use crate::engine::EngineConfig;

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

    let resolved = config.resolve_seasonal_baselines();
    assert_eq!(resolved.len(), 1);
    let profile = resolved
        .get("series-a")
        .expect("series-a baseline resolves");
    // Only the in-range (dow 1, hod 9) bucket survives; dow 9 and hod 30 are dropped.
    assert_eq!(profile.populated_bucket_count(), 1);
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
