// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Operator-supplied configuration and the resolved settings/counters derived
//! from it for the [`crate::AnomalyAddon`].

use std::collections::HashMap;
use std::fmt::Display;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize as _, de::Error as _};
use serviceradar_anomaly_core::SeasonalBucket;

use crate::engine::DriftMode;
use crate::engine::{
    DEFAULT_ANCHOR_MAX_AGE_SECS, DEFAULT_DRIFT_ADOPT_AFTER_SAMPLES, DEFAULT_DRIFT_CLEAR_SLOTS,
    DEFAULT_DRIFT_CONFIRM_WINDOW, DEFAULT_DRIFT_MIN_EFFECT, DEFAULT_EPISODE_UPDATE_INTERVAL_SECS,
    DEFAULT_H_CONFIRM_MULT, DEFAULT_METRIC_DENYLIST, DEFAULT_REOPEN_COOLDOWN_SECS,
    DEFAULT_SPIKE_ADOPT_AFTER_SAMPLES,
};
use crate::engine::{
    DEFAULT_CRITICAL_MIN_DURATION_SECS, DEFAULT_CUSUM_H, DEFAULT_DRIFT_ESCALATE_AFTER_SECS,
    DEFAULT_EMISSION_BUDGET_PER_TICK, DEFAULT_EMISSION_COOLDOWN_SECS, EngineConfig,
    MetricClassOverride, SeasonalProfile, SeasonalSettings, SeverityPolicy,
};

pub(crate) const ADDON_ID: &str = "anomaly";
pub(crate) const ADDON_VERSION: &str = "0.3.6";
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
    /// Core-projected settings from the Anomaly Detection singleton. These are
    /// lower precedence than operator-explicit top-level params on the profile.
    #[serde(default)]
    pub(crate) managed: Option<ManagedConfig>,
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
    /// CUSUM slack (reference value `k`) in sigma units (default 0.5).
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) cusum_k: Option<f64>,
    /// CUSUM decision interval (`h`, the alarm threshold; default 8.0).
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) cusum_h: Option<f64>,
    /// Confirmation threshold multiplier; emit only after crossing h * multiplier.
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) h_confirm_mult: Option<f64>,
    /// Samples after pending latch allowed to reach confirmation threshold.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_confirm_window: Option<u64>,
    /// Minimum estimated sustained shift (`k + S/N`, in sigma units) before a
    /// CUSUM alarm emits a drift finding.
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) drift_min_effect: Option<f64>,
    /// Consecutive recovered samples before an open drift episode clears.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_clear_slots: Option<u64>,
    /// Samples after open before a persistent new level is adopted and cleared.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_adopt_after_samples: Option<u64>,
    /// Samples after a continuously anomalous rolling spike before the stable
    /// level is adopted into the rolling baseline and the episode clears.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) spike_adopt_after_samples: Option<u64>,
    /// Seconds between still-open drift heartbeat updates.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) episode_update_interval_secs: Option<u64>,
    /// Seconds after a clear during which a re-open reuses the episode identity.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) reopen_cooldown_secs: Option<u64>,
    /// Maximum age for an idle always-on rolling CUSUM anchor before refresh.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) anchor_max_age_secs: Option<u64>,
    /// Minimum episode duration before a High spike can become Critical.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) critical_min_duration_secs: Option<u64>,
    /// Minimum open drift duration before Medium drift can escalate to High.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_escalate_after_secs: Option<u64>,
    /// Minimum seconds between non-clear emissions for one detector series.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) emission_cooldown_secs: Option<u64>,
    /// Maximum non-clear anomaly records emitted per frame/tick before rollup.
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) emission_budget_per_tick: Option<usize>,
    /// Additive nested emission config. Flat legacy keys remain honored for one
    /// release; nested values take precedence when both are present.
    #[serde(default)]
    pub(crate) emission: Option<EmissionConfig>,
    /// Additive per-class override surface projected by core.
    #[serde(default)]
    pub(crate) metric_classes: Option<HashMap<String, MetricClassConfig>>,
    /// Metric names that should not produce detector findings. Omitted uses the
    /// built-in denylist; an explicit empty list disables the denylist.
    #[serde(default)]
    pub(crate) metric_denylist: Option<Vec<String>>,
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
    /// Optional per-series hour-of-week seasonal baselines delivered from core,
    /// keyed by the canonical `<device_uid>|<metric_name>` (central's `series:uid`
    /// profile keyspace — see [`crate::identity::seasonal_series_key`]), NOT the
    /// fine detector series key. Each carries up to 168 `(dow, hod)` buckets with a
    /// robust `{center, scale}` summary the detector deseasonalizes against.
    /// Omitted/empty keeps every series on the rolling-only path (back-compat).
    #[serde(default)]
    pub(crate) seasonal: Option<SeasonalConfig>,
    /// Delivered per-series hour-of-week baselines.
    #[serde(default)]
    pub(crate) seasonal_baselines: Option<HashMap<String, SeasonalBaselineConfig>>,
}

/// Core-managed defaults projected into `params.managed`. This intentionally
/// mirrors only the Settings singleton fields that should reach the edge.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub(crate) struct ManagedConfig {
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) window_size: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) min_samples: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) n_sigma: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) confirm_slots: Option<usize>,
    #[serde(default)]
    pub(crate) emission: Option<EmissionConfig>,
    #[serde(default)]
    pub(crate) metric_denylist: Option<Vec<String>>,
    #[serde(default)]
    pub(crate) metric_classes: Option<HashMap<String, MetricClassConfig>>,
}

/// Nested emission governance knobs. Mirrors the OpenSpec/projected config shape
/// while preserving the legacy flat keys in [`AddonConfig`].
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub(crate) struct EmissionConfig {
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) cooldown_secs: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) budget_per_tick: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) episode_update_interval_secs: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) reopen_cooldown_secs: Option<u64>,
}

/// Additive per-class config surface accepted from core. The runtime applies the
/// class enable switch, drift mode, and dispersion floors here; numeric CUSUM
/// threshold splitting remains global until the drift state machine grows
/// per-class threshold state.
#[allow(dead_code)]
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub(crate) struct MetricClassConfig {
    #[serde(default, deserialize_with = "deserialize_optional_bool")]
    pub(crate) enabled: Option<bool>,
    #[serde(default)]
    pub(crate) drift_mode: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) cusum_k: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) cusum_h: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) h_confirm_mult: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_confirm_window: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_clear_slots: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) drift_min_effect: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_adopt_after_samples: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) spike_adopt_after_samples: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    pub(crate) drift_escalate_after_secs: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) min_std_floor: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) min_cv: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) drift_min_cv: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    pub(crate) abs_effect_floor: Option<f64>,
    #[serde(default)]
    pub(crate) severity_cap: Option<String>,
    #[serde(default)]
    pub(crate) severity_bands: Option<serde_json::Value>,
}

/// Seasonal payload-governance knobs for delivered edge baselines.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub(crate) struct SeasonalConfig {
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) max_baselines: Option<usize>,
    /// Core writes the exact per-bucket history gate alongside the delivered
    /// payload so edge trust cannot silently drift from delivery eligibility.
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    pub(crate) min_bucket_samples: Option<usize>,
}

/// Wire form of one series' delivered hour-of-week baseline.
#[derive(Debug, Clone, serde::Deserialize)]
pub(crate) struct SeasonalBaselineConfig {
    #[serde(default)]
    pub(crate) buckets: Vec<SeasonalBucketConfig>,
    /// Compact 168-slot center array. JSON has no f32 type; core rounds values to
    /// float32 precision before delivery, and the edge stores them as f64 for the
    /// existing detector math.
    #[serde(default)]
    pub(crate) centers: Vec<Option<f64>>,
    #[serde(default)]
    pub(crate) scales: Vec<Option<f64>>,
    #[serde(default)]
    pub(crate) sample_counts: Vec<Option<u64>>,
}

/// Wire form of one `(dow, hod)` seasonal bucket: a robust center (median) + scale
/// (robust dispersion in metric units) and the historical sample count that backed
/// them. `dow` is 0..=6 (Sun=0), `hod` is 0..=23.
#[derive(Debug, Clone, serde::Deserialize)]
pub(crate) struct SeasonalBucketConfig {
    pub(crate) dow: u32,
    pub(crate) hod: u32,
    pub(crate) center: f64,
    pub(crate) scale: f64,
    #[serde(default)]
    pub(crate) sample_count: u64,
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

/// Tolerant optional bool: accepts a JSON bool, null, or a string form
/// (`"true"`/`"false"`/`"1"`/`"0"`, empty = unset), mirroring the string-tolerant
/// number knobs so a control plane that stringifies config still parses.
fn deserialize_optional_bool<'de, D>(deserializer: D) -> Result<Option<bool>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let Some(value) = Option::<serde_json::Value>::deserialize(deserializer)? else {
        return Ok(None);
    };

    match value {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::Bool(value) => Ok(Some(value)),
        serde_json::Value::String(value) => match value.trim().to_ascii_lowercase().as_str() {
            "" => Ok(None),
            "true" | "1" | "yes" => Ok(Some(true)),
            "false" | "0" | "no" => Ok(Some(false)),
            other => Err(D::Error::custom(format!("invalid bool: {other}"))),
        },
        other => Err(D::Error::custom(format!("invalid bool: {other}"))),
    }
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
    pub(crate) fn resolve_seasonal_settings(&self) -> SeasonalSettings {
        let mut settings = SeasonalSettings::default();

        if let Some(min_bucket_samples) = self
            .seasonal
            .as_ref()
            .and_then(|seasonal| seasonal.min_bucket_samples)
            .filter(|value| *value > 0)
        {
            settings.min_bucket_samples = min_bucket_samples;
        }

        settings
    }

    /// Resolve the delivered wire baselines into the engine's per-series
    /// [`SeasonalProfile`] map. Buckets with an out-of-range `(dow, hod)` or a
    /// non-finite center/scale are dropped. Returns an empty map when nothing was
    /// delivered, so the engine stays on the rolling-only path (back-compat).
    pub(crate) fn resolve_seasonal_baselines(&self) -> HashMap<String, SeasonalProfile> {
        let Some(baselines) = self.seasonal_baselines.as_ref() else {
            return HashMap::new();
        };
        let max_baselines = self
            .seasonal
            .as_ref()
            .and_then(|seasonal| seasonal.max_baselines)
            .unwrap_or(usize::MAX);
        let mut entries: Vec<_> = baselines.iter().collect();
        entries.sort_by_key(|(left, _)| *left);

        entries
            .into_iter()
            .take(max_baselines)
            .map(|(series_key, baseline)| {
                let object_buckets = baseline.buckets.iter().filter_map(|bucket| {
                    if bucket.dow > 6 || bucket.hod > 23 {
                        return None;
                    }
                    if !bucket.center.is_finite() || !bucket.scale.is_finite() {
                        return None;
                    }

                    let index = bucket.dow as usize * 24 + bucket.hod as usize;
                    Some((
                        index,
                        SeasonalBucket {
                            center: bucket.center,
                            scale: bucket.scale,
                            sample_count: bucket.sample_count as usize,
                        },
                    ))
                });

                let compact_buckets =
                    (0..serviceradar_anomaly_core::HOURS_PER_WEEK).filter_map(|index| {
                        let center = baseline.centers.get(index).copied().flatten()?;
                        let scale = baseline.scales.get(index).copied().flatten()?;

                        if !center.is_finite() || !scale.is_finite() {
                            return None;
                        }

                        let sample_count = baseline
                            .sample_counts
                            .get(index)
                            .copied()
                            .flatten()
                            .unwrap_or_default()
                            as usize;

                        Some((
                            index,
                            SeasonalBucket {
                                center,
                                scale,
                                sample_count,
                            },
                        ))
                    });

                (
                    series_key.clone(),
                    SeasonalProfile::from_buckets(object_buckets.chain(compact_buckets)),
                )
            })
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn metric_class_override_count(&self) -> usize {
        self.metric_classes.as_ref().map_or_else(
            || {
                self.managed
                    .as_ref()
                    .and_then(|managed| managed.metric_classes.as_ref())
                    .map_or(0, HashMap::len)
            },
            HashMap::len,
        )
    }

    pub(crate) fn into_engine_config(self) -> Result<EngineConfig, String> {
        let base = EngineConfig::default();
        let managed = self.managed.as_ref().cloned().unwrap_or_default();
        let window_size = self
            .window_size
            .or(managed.window_size)
            .unwrap_or(base.window_size)
            .max(1);
        let min_samples = self
            .min_samples
            .or(managed.min_samples)
            .unwrap_or(base.min_samples)
            .max(1);
        let managed_emission = managed.emission.clone().unwrap_or_default();
        let emission = self.emission.unwrap_or_default();
        let metric_class_overrides = resolve_metric_class_overrides(
            self.metric_classes
                .as_ref()
                .or(managed.metric_classes.as_ref()),
        );

        if min_samples > window_size {
            return Err(format!(
                "min_samples ({min_samples}) must be less than or equal to window_size ({window_size})"
            ));
        }

        Ok(EngineConfig {
            window_size,
            min_samples,
            n_sigma: self.n_sigma.or(managed.n_sigma).unwrap_or(base.n_sigma),
            confirm_slots: self
                .confirm_slots
                .or(managed.confirm_slots)
                .unwrap_or(base.confirm_slots)
                .max(1),
            max_series: self.max_series.unwrap_or(base.max_series).max(1),
            // Only accept a finite, positive override; a 0/negative/NaN value is
            // treated as "unset" so it can never weaken a gauge's safe floor.
            min_std_floor: self.min_std_floor.filter(|v| v.is_finite() && *v > 0.0),
            min_cv: self.min_cv.filter(|v| v.is_finite() && *v > 0.0),
            // CUSUM enablement is per metric class via `drift_mode`; the legacy
            // top-level `cusum_enabled` key is intentionally not modeled in 0.2.0
            // so stale profile data cannot disable drift globally.
            cusum_k: self
                .cusum_k
                .filter(|v| v.is_finite() && *v >= 0.0)
                .unwrap_or(base.cusum_k),
            cusum_h: self
                .cusum_h
                .filter(|v| v.is_finite() && *v > 0.0)
                .unwrap_or(DEFAULT_CUSUM_H),
            h_confirm_mult: self
                .h_confirm_mult
                .filter(|v| v.is_finite() && *v >= 1.0)
                .unwrap_or(DEFAULT_H_CONFIRM_MULT),
            drift_confirm_window: self
                .drift_confirm_window
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_DRIFT_CONFIRM_WINDOW),
            drift_min_effect: self
                .drift_min_effect
                .filter(|v| v.is_finite() && *v > 0.0)
                .unwrap_or(DEFAULT_DRIFT_MIN_EFFECT),
            drift_clear_slots: self
                .drift_clear_slots
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_DRIFT_CLEAR_SLOTS),
            drift_adopt_after_samples: self
                .drift_adopt_after_samples
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_DRIFT_ADOPT_AFTER_SAMPLES),
            spike_adopt_after_samples: self
                .spike_adopt_after_samples
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_SPIKE_ADOPT_AFTER_SAMPLES),
            episode_update_interval_secs: emission
                .episode_update_interval_secs
                .or(self.episode_update_interval_secs)
                .or(managed_emission.episode_update_interval_secs)
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_EPISODE_UPDATE_INTERVAL_SECS),
            reopen_cooldown_secs: emission
                .reopen_cooldown_secs
                .or(self.reopen_cooldown_secs)
                .or(managed_emission.reopen_cooldown_secs)
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_REOPEN_COOLDOWN_SECS),
            anchor_max_age_secs: self
                .anchor_max_age_secs
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_ANCHOR_MAX_AGE_SECS),
            critical_min_duration_secs: self
                .critical_min_duration_secs
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_CRITICAL_MIN_DURATION_SECS),
            drift_escalate_after_secs: self
                .drift_escalate_after_secs
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_DRIFT_ESCALATE_AFTER_SECS),
            emission_cooldown_secs: emission
                .cooldown_secs
                .or(self.emission_cooldown_secs)
                .or(managed_emission.cooldown_secs)
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_EMISSION_COOLDOWN_SECS),
            emission_budget_per_tick: emission
                .budget_per_tick
                .or(self.emission_budget_per_tick)
                .or(managed_emission.budget_per_tick)
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_EMISSION_BUDGET_PER_TICK),
            metric_denylist: self
                .metric_denylist
                .or_else(|| managed.metric_denylist.clone())
                .map(sanitize_metric_denylist)
                .unwrap_or_else(default_metric_denylist),
            metric_class_overrides,
        })
    }
}

fn resolve_metric_class_overrides(
    configs: Option<&HashMap<String, MetricClassConfig>>,
) -> HashMap<String, MetricClassOverride> {
    let Some(configs) = configs else {
        return HashMap::new();
    };

    configs
        .iter()
        .filter_map(|(class, config)| {
            let class = normalize_metric_class_key(class)?;
            let class_override = MetricClassOverride {
                enabled: config.enabled,
                drift_mode: config.drift_mode.as_deref().and_then(parse_drift_mode),
                min_std_floor: finite_positive(config.min_std_floor),
                min_cv: finite_positive(config.min_cv),
                drift_min_cv: finite_positive(config.drift_min_cv),
                abs_effect_floor: finite_positive(config.abs_effect_floor),
                spike_adopt_after_samples: config.spike_adopt_after_samples.filter(|v| *v > 0),
                severity_policy: severity_policy_from(
                    config.severity_cap.as_deref(),
                    config.severity_bands.as_ref(),
                ),
            };

            Some((class, class_override))
        })
        .collect()
}

fn normalize_metric_class_key(class: &str) -> Option<String> {
    let trimmed = class.trim();
    if trimmed.is_empty() {
        return None;
    }

    Some(trimmed.to_ascii_lowercase())
}

fn parse_drift_mode(value: &str) -> Option<DriftMode> {
    match value.trim().to_ascii_lowercase().as_str() {
        "off" => Some(DriftMode::Off),
        "deseasonalized_only" => Some(DriftMode::DeseasonalizedOnly),
        "always" => Some(DriftMode::Always),
        _ => None,
    }
}

fn finite_positive(value: Option<f64>) -> Option<f64> {
    value.filter(|value| value.is_finite() && *value > 0.0)
}

fn severity_policy_from(
    severity_cap: Option<&str>,
    severity_bands: Option<&serde_json::Value>,
) -> SeverityPolicy {
    let cap = severity_cap.and_then(|value| match value.trim().to_ascii_lowercase().as_str() {
        "low" => Some(2),
        "medium" => Some(3),
        "high" => Some(4),
        "critical" => Some(5),
        _ => None,
    });
    let numeric_band = |key: &str| {
        severity_bands
            .and_then(serde_json::Value::as_object)
            .and_then(|bands| bands.get(key))
            .and_then(|value| match value {
                serde_json::Value::Number(value) => value.as_f64(),
                serde_json::Value::String(value) => value.trim().parse::<f64>().ok(),
                _ => None,
            })
            .filter(|value| value.is_finite() && *value > 0.0)
    };

    SeverityPolicy {
        cap,
        medium_at: numeric_band("medium"),
        high_at: numeric_band("high"),
    }
}

fn default_metric_denylist() -> Vec<String> {
    DEFAULT_METRIC_DENYLIST
        .iter()
        .map(|name| (*name).to_string())
        .collect()
}

fn sanitize_metric_denylist(values: Vec<String>) -> Vec<String> {
    let mut denylist = Vec::new();

    for value in values {
        let metric_name = value.trim();
        if metric_name.is_empty() || denylist.iter().any(|existing| existing == metric_name) {
            continue;
        }
        denylist.push(metric_name.to_string());
    }

    denylist
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

#[cfg(test)]
mod addon_config_contract_tests {
    use super::AddonConfig;

    /// fj#4383 add-on config contract test: decodes the committed
    /// core-emitted `config_json` fixture with the REAL add-on decoder so
    /// core's delivery-path emitter and this struct cannot drift apart.
    /// Regenerate the fixture with
    /// `cd elixir/serviceradar_core && mix serviceradar.gen.addon_contract_fixtures`.
    const CORE_EMITTED_FIXTURE: &str =
        include_str!("../../../go/pkg/agent/testdata/addonconfig_contract/anomaly-addon.json");

    #[test]
    fn decodes_core_emitted_contract_fixture() {
        let cfg: AddonConfig = serde_json::from_str(CORE_EMITTED_FIXTURE)
            .expect("core-emitted anomaly-addon config_json must decode with the real decoder");

        // The decoder is lenient (unknown keys ignored), so assert the values
        // round-tripped instead of relying on decode failure alone.
        assert_eq!(cfg.window_size, Some(300));
        assert_eq!(cfg.min_samples, Some(30));
        assert_eq!(cfg.n_sigma, Some(3.5));
        assert_eq!(cfg.confirm_slots, Some(5));
        assert_eq!(cfg.max_series, Some(50_000));
        assert_eq!(cfg.cusum_k, Some(0.5));
        assert_eq!(cfg.cusum_h, Some(5.0));
        assert_eq!(
            cfg.checkpoint_path.as_deref(),
            Some("/var/lib/serviceradar/anomaly/checkpoint.bin")
        );
        assert_eq!(cfg.checkpoint_max_age_secs, Some(21_600));
        let engine_cfg = cfg
            .into_engine_config()
            .expect("core-emitted fixture must resolve to engine config");
        assert_eq!(engine_cfg.cusum_k, 0.5);
        assert_eq!(engine_cfg.cusum_h, 5.0);
        assert!(engine_cfg.metric_class_overrides.is_empty());
        // `metric_feed` in the schema/fixture is core-side feed routing
        // (stream_metric_feed), deliberately NOT a field of AddonConfig.
    }
}
