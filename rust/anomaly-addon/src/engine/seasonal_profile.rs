// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Optional hour-of-week deseasonalization inputs delivered from core: the
//! per-series 168-bucket seasonal profile, the thresholds governing the seasonal
//! signal, and the resolved per-sample seasonal context. Named distinctly from
//! anomaly-core's `seasonal` to avoid confusion — this is the edge-side delivery
//! container, not the core math.

use serviceradar_anomaly_core::{HOURS_PER_WEEK, SeasonalBucket};

/// Default minimum historical points a delivered hour-of-week bucket must carry
/// before the edge trusts it as a seasonal baseline. Mirrors central
/// seasonal-disposition's `@default_min_bucket_samples` (4).
pub const DEFAULT_SEASONAL_MIN_BUCKET_SAMPLES: usize = 4;
/// Default length of the reconstructed synthetic seasonal window. Large enough to
/// clear the signal's own min-samples gate; clamped to the window size at scoring.
pub const DEFAULT_SEASONAL_SYNTHETIC_LEN: usize = 32;

/// Thresholds governing the optional hour-of-week deseasonalization. Independent
/// of [`EngineConfig`] so a detector with no delivered baselines is byte-for-byte
/// the prior rolling-only engine.
#[derive(Clone, Copy, Debug)]
pub struct SeasonalSettings {
    /// Breach threshold (sigma) for the seasonal signal. Falls back to the engine
    /// rolling `n_sigma` when not finite/positive.
    pub n_sigma: Option<f64>,
    /// Minimum historical points a delivered bucket must carry before it is
    /// trusted (a bucket with too little history is ignored, leaving the series on
    /// the rolling-only path).
    pub min_bucket_samples: usize,
    /// Length of the reconstructed synthetic seasonal window; clamped to
    /// `[2, window_size]` at scoring time so the window is never truncated.
    pub synthetic_len: usize,
}

impl Default for SeasonalSettings {
    fn default() -> Self {
        Self {
            n_sigma: None,
            min_bucket_samples: DEFAULT_SEASONAL_MIN_BUCKET_SAMPLES,
            synthetic_len: DEFAULT_SEASONAL_SYNTHETIC_LEN,
        }
    }
}

/// One series' 168-bucket hour-of-week seasonal baseline, delivered from core.
/// Each populated bucket carries a robust `{center, scale}` summary the edge
/// expands into the detector's `seasonal_baseline` at scoring time.
#[derive(Clone, Debug, Default)]
pub struct SeasonalProfile {
    buckets: Vec<Option<SeasonalBucket>>,
}

impl SeasonalProfile {
    /// Build a profile from `(hour_of_week_index, bucket)` pairs. Indices outside
    /// `0..168` are ignored; a later entry for the same index wins.
    pub fn from_buckets(entries: impl IntoIterator<Item = (usize, SeasonalBucket)>) -> Self {
        let mut buckets = vec![None; HOURS_PER_WEEK];
        for (index, bucket) in entries {
            if index < HOURS_PER_WEEK {
                buckets[index] = Some(bucket);
            }
        }
        Self { buckets }
    }

    pub(crate) fn bucket(&self, index: usize) -> Option<SeasonalBucket> {
        self.buckets.get(index).copied().flatten()
    }

    /// How many of the 168 hour-of-week buckets carry a delivered baseline.
    pub fn populated_bucket_count(&self) -> usize {
        self.buckets
            .iter()
            .filter(|bucket| bucket.is_some())
            .count()
    }
}

/// The resolved hour-of-week seasonal signal for one sample: the reconstructed
/// synthetic baseline window plus the min-samples and sigma knobs it scores
/// against. Returned (as `Some`) only when a delivered bucket is usable for this
/// series at this sample's hour-of-week; `None` is the back-compat rolling-only
/// path. (A named struct rather than a 4-tuple `Option`, which also clears the
/// `clippy::type_complexity` lint on the resolver.)
pub(crate) struct SeasonalContext {
    pub(crate) baseline: Vec<f64>,
    pub(crate) min_samples: usize,
    pub(crate) n_sigma: f64,
}
