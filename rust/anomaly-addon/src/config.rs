// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Operator-supplied configuration and the resolved settings/counters derived
//! from it for the [`crate::AnomalyAddon`].

use std::fmt::Display;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize as _, de::Error as _};

use crate::engine::EngineConfig;

pub(crate) const ADDON_ID: &str = "anomaly";
pub(crate) const ADDON_VERSION: &str = "0.1.20";
pub(crate) const VERDICT_CHANNEL_DEPTH: usize = 256;
pub(crate) const ACK_CHANNEL_DEPTH: usize = 64;
pub(crate) const OCSF_CLASS_EVENT_LOG_ACTIVITY: i64 = 1008;
pub(crate) const OCSF_CATEGORY_SYSTEM_ACTIVITY: i64 = 1;
pub(crate) const OCSF_ACTIVITY_CREATE: i64 = 1;
pub(crate) const OCSF_VERSION: &str = "1.7.0";

/// Default restart-checkpoint staleness bound (6h): a baseline whose last reading
/// is older than this is not reseeded on restart.
pub(crate) const DEFAULT_CHECKPOINT_MAX_AGE_NS: u64 = 6 * 60 * 60 * 1_000_000_000;
/// Default checkpoint cadence: persist after every N processed feed frames.
pub(crate) const DEFAULT_CHECKPOINT_WRITE_EVERY: u64 = 100;
/// Default scoring liveness staleness bound (5m): once scoring has started,
/// health degrades if no scored frame completes within this age.
pub(crate) const DEFAULT_SCORING_STALE_AFTER_NS: u64 = 5 * 60 * 1_000_000_000;

/// Operator-supplied configuration (validated by the control plane against
/// `config.schema.json`). All fields optional; omitted ones keep the defaults.
#[derive(Debug, Default, serde::Deserialize)]
pub(crate) struct AddonConfig {
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) window_size: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) min_samples: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) n_sigma: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) confirm_slots: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) max_series: Option<usize>,
    /// Optional GLOBAL dispersion-floor overrides (fix #2). When set, these only
    /// ever RAISE a series' built-in per-class floor (max), letting an operator
    /// tighten the whole fleet without per-class tuning. Omitted leaves every
    /// series on its built-in default (0 for non-gauges, the gauge defaults for
    /// cpu/mem/disk). The central metric_class override channel remains a
    /// follow-up; this flat knob is the edge-only global override.
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) min_std_floor: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) min_cv: Option<f64>,
    /// Local path the add-on persists its per-series checkpoint to so a restart
    /// re-warms baselines instead of cold-starting. Unset disables checkpointing.
    pub(crate) checkpoint_path: Option<String>,
    /// Restart staleness bound in seconds (default 6h); series older than this
    /// are not reseeded.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) checkpoint_max_age_secs: Option<u64>,
    /// Liveness staleness bound in seconds (default 5m); once scoring has
    /// started, health degrades if no frame finishes scoring within this age.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) scoring_stale_after_secs: Option<u64>,
}

fn deserialize_optional_usize<'de, D>(deserializer: D) -> Result<Option<usize>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    deserialize_optional_number(deserializer)
}

fn deserialize_optional_u64<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    deserialize_optional_number(deserializer)
}

fn deserialize_optional_f64<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    deserialize_optional_number(deserializer)
}

fn deserialize_optional_number<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::de::DeserializeOwned + FromStr,
    T::Err: Display,
{
    let Some(value) = Option::<serde_json::Value>::deserialize(deserializer)? else {
        return Ok(None);
    };

    match value {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::String(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                trimmed.parse::<T>().map(Some).map_err(D::Error::custom)
            }
        }
        value => serde_json::from_value::<T>(value)
            .map(Some)
            .map_err(D::Error::custom),
    }
}

/// Resolved checkpoint behavior derived from [`AddonConfig`]. `path` unset means
/// checkpointing is disabled (the add-on still runs, just cold-starts on restart).
#[derive(Clone)]
pub(crate) struct CheckpointSettings {
    pub(crate) path: Option<PathBuf>,
    pub(crate) max_age_ns: u64,
    pub(crate) write_every: u64,
}

impl Default for CheckpointSettings {
    fn default() -> Self {
        Self {
            path: None,
            max_age_ns: DEFAULT_CHECKPOINT_MAX_AGE_NS,
            write_every: DEFAULT_CHECKPOINT_WRITE_EVERY,
        }
    }
}

impl AddonConfig {
    pub(crate) fn into_engine_config(self) -> Result<EngineConfig, String> {
        let base = EngineConfig::default();
        let window_size = self.window_size.unwrap_or(base.window_size).max(1);
        let min_samples = self.min_samples.unwrap_or(base.min_samples).max(1);

        if min_samples > window_size {
            return Err(format!(
                "min_samples ({min_samples}) must be less than or equal to window_size ({window_size})"
            ));
        }

        Ok(EngineConfig {
            window_size,
            min_samples,
            n_sigma: self.n_sigma.unwrap_or(base.n_sigma),
            confirm_slots: self.confirm_slots.unwrap_or(base.confirm_slots).max(1),
            max_series: self.max_series.unwrap_or(base.max_series).max(1),
            // Only accept a finite, positive override; a 0/negative/NaN value is
            // treated as "unset" so it can never weaken a gauge's safe floor.
            min_std_floor: self.min_std_floor.filter(|v| v.is_finite() && *v > 0.0),
            min_cv: self.min_cv.filter(|v| v.is_finite() && *v > 0.0),
        })
    }
}

#[derive(Default)]
pub(crate) struct NativeTelemetryDropCounters {
    no_subscriber_batches: AtomicU64,
    // Broadcast lag is reported per receiver. This is a delivery-failure volume
    // counter, so one skipped batch observed by two lagging receivers counts as
    // two lagged receiver-batches.
    lagged_batches: AtomicU64,
    outbound_full_batches: AtomicU64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct NativeTelemetryDropSnapshot {
    pub(crate) no_subscriber_batches: u64,
    pub(crate) lagged_batches: u64,
    pub(crate) outbound_full_batches: u64,
}

impl NativeTelemetryDropCounters {
    pub(crate) fn record_no_subscriber_batch(&self) {
        self.no_subscriber_batches.fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn record_lagged_batches(&self, count: u64) {
        self.lagged_batches.fetch_add(count, Ordering::Relaxed);
    }

    pub(crate) fn record_outbound_full_batch(&self) {
        self.outbound_full_batches.fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn snapshot(&self) -> NativeTelemetryDropSnapshot {
        NativeTelemetryDropSnapshot {
            no_subscriber_batches: self.no_subscriber_batches.load(Ordering::Relaxed),
            lagged_batches: self.lagged_batches.load(Ordering::Relaxed),
            outbound_full_batches: self.outbound_full_batches.load(Ordering::Relaxed),
        }
    }
}

impl NativeTelemetryDropSnapshot {
    pub(crate) fn total(self) -> u64 {
        self.no_subscriber_batches + self.lagged_batches + self.outbound_full_batches
    }

    pub(crate) fn health_message(self) -> String {
        format!(
            "native telemetry delivery drops: total={} no_subscriber_batches={} lagged_receiver_batches={} outbound_full_batches={}",
            self.total(),
            self.no_subscriber_batches,
            self.lagged_batches,
            self.outbound_full_batches
        )
    }
}
