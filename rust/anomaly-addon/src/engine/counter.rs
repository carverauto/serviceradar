// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Cumulative-counter rate normalization: the reset-lineage / gap / wrap rules
//! that turn a raw monotonic counter into the per-second rate the detector can
//! z-score, mirroring central `CounterNormalizer` so edge verdicts match.

use super::DetectorEngine;
use super::state::CounterState;

/// A gap longer than this between two counter readings is treated as a
/// discontinuity (agent restart, missed polls) rather than a rate. 2 hours,
/// matching central `CounterNormalizer`'s `@default_max_gap_ns`.
pub(crate) const COUNTER_MAX_GAP_NS: u64 = 2 * 60 * 60 * 1_000_000_000;

/// 2^32 — the 32-bit counter modulus and the default max plausible per-second
/// rate used to sanity-check a wrap (central `@counter32_modulus`).
pub(crate) const COUNTER32_MODULUS: f64 = 4_294_967_296.0;

impl DetectorEngine {
    /// Rate-normalize one cumulative-monotonic counter reading against this
    /// series' previous reading, mirroring central `CounterNormalizer`: returns
    /// `Some(rate_per_second)` when a safe rate is computable, or `None` on the
    /// first reading (warmup), a reset-lineage change, non-monotonic time, an
    /// over-long gap, or an implausible decrease. Per-series state advances
    /// exactly as central advances it (no advance on non-monotonic time).
    ///
    /// `counter_width` is the PDU width (32/64); a decrease is only salvaged as a
    /// plausible 32-bit wrap. The returned rate is what should be fed to
    /// [`Self::evaluate`] in place of the raw counter value.
    pub fn normalize_counter(
        &mut self,
        series_key: &str,
        raw_value: f64,
        observed_at_unix_nano: u64,
        reset_anchor: &str,
        counter_width: u32,
    ) -> Option<f64> {
        self.normalize_counter_with_max_rate(
            series_key,
            raw_value,
            observed_at_unix_nano,
            reset_anchor,
            counter_width,
            None,
        )
    }

    /// Same as [`Self::normalize_counter`], but lets the caller pass a
    /// per-sample plausible maximum rate when the producer knows the physical
    /// counter bound (for example an interface speed).
    pub fn normalize_counter_with_max_rate(
        &mut self,
        series_key: &str,
        raw_value: f64,
        observed_at_unix_nano: u64,
        reset_anchor: &str,
        counter_width: u32,
        max_counter_rate_per_second: Option<f64>,
    ) -> Option<f64> {
        if !raw_value.is_finite() || raw_value < 0.0 {
            return None;
        }

        let Some(previous) = self.counters.get_mut(series_key) else {
            // Warmup: store the first reading, emit nothing (a rate needs two).
            if self.counters.len() >= self.config.max_series {
                self.evict_stale_state_once_per_timestamp(observed_at_unix_nano);
            }
            if self.counters.len() >= self.config.max_series {
                self.dropped_at_capacity = self.dropped_at_capacity.saturating_add(1);
                return None;
            }
            self.counters.insert(
                series_key.to_owned(),
                CounterState {
                    value: raw_value,
                    timestamp: observed_at_unix_nano,
                    reset_anchor: reset_anchor.to_owned(),
                },
            );
            return None;
        };

        // Reset lineage changed (counter restart): store, drop — a rate across a
        // reset is meaningless.
        if reset_anchor_changed(&previous.reset_anchor, reset_anchor) {
            previous.value = raw_value;
            previous.timestamp = observed_at_unix_nano;
            replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);
            return None;
        }

        // Non-monotonic time: drop WITHOUT advancing, keeping the older valid
        // reading as the baseline (matches central) — UNLESS the stored baseline is
        // implausibly far AHEAD of this reading (more than COUNTER_MAX_GAP_NS). A
        // single point carrying a bad future timestamp would otherwise become the
        // baseline and silently drop every subsequent real reading (each is "older")
        // until wall-clock catches up — and that poisoned future timestamp is immune
        // to age-based eviction and survives the checkpoint. When the backward jump
        // is that large the STORED timestamp is the suspect, so re-anchor to this
        // reading (symmetric with the over-long forward gap below) and recover on the
        // next real point. A small backward step (clock skew) still drops, as before.
        if observed_at_unix_nano <= previous.timestamp {
            if previous.timestamp - observed_at_unix_nano > COUNTER_MAX_GAP_NS {
                previous.value = raw_value;
                previous.timestamp = observed_at_unix_nano;
                replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);
            }
            return None;
        }

        // Over-long gap: store, drop — treat as a discontinuity, not a rate.
        if observed_at_unix_nano - previous.timestamp > COUNTER_MAX_GAP_NS {
            previous.value = raw_value;
            previous.timestamp = observed_at_unix_nano;
            replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);
            return None;
        }

        let elapsed_seconds = (observed_at_unix_nano - previous.timestamp) as f64 / 1_000_000_000.0;
        let delta = counter_delta(
            previous.value,
            raw_value,
            counter_width,
            elapsed_seconds,
            max_counter_rate_per_second,
        );

        // Advance across the interval whether or not a delta was salvageable
        // (central stores `current` on both the ok and decrease-drop branches).
        previous.value = raw_value;
        previous.timestamp = observed_at_unix_nano;
        replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);

        match delta {
            Some(d) if elapsed_seconds > 0.0 => Some(d / elapsed_seconds),
            _ => None,
        }
    }
}

/// A reset is only declared when both anchors are known AND differ; an empty
/// anchor on either side is "unknown" and never forces a reset (matches central's
/// nil-tolerant `reset_anchor_changed?`).
fn reset_anchor_changed(previous: &str, current: &str) -> bool {
    !previous.is_empty() && !current.is_empty() && previous != current
}

fn replace_reset_anchor(target: &mut String, current: &str) {
    // An empty (unknown) anchor must NOT clobber a known one. `reset_anchor_changed`
    // treats empty on either side as "unknown, never a reset", so if we let an empty
    // anchor overwrite a stored "boot-1", a later genuine "boot-2" would compare
    // against "" and the real reset would be missed. Preserve the last known anchor
    // instead. (Also preserves the in-place no-realloc fast path on no change.)
    if current.is_empty() || target == current {
        return;
    }

    target.clear();
    target.push_str(current);
}

/// The counter increment over one interval: a normal increase is `current -
/// previous`; a decrease is salvaged only as a plausible 32-bit wrap (the wrapped
/// delta must imply a per-second rate within the supplied per-sample max, falling
/// back to the 32-bit modulus). A 64-bit/unknown-width decrease, or an implausible
/// 32-bit decrease, yields `None` (drop the interval).
fn counter_delta(
    previous: f64,
    current: f64,
    counter_width: u32,
    elapsed_seconds: f64,
    max_counter_rate_per_second: Option<f64>,
) -> Option<f64> {
    if elapsed_seconds <= 0.0 {
        return None;
    }

    if current >= previous {
        return plausible_counter_delta(
            current - previous,
            elapsed_seconds,
            valid_counter_max_rate(max_counter_rate_per_second),
        );
    }

    if counter_width == 32 {
        let wrapped = COUNTER32_MODULUS - previous + current;
        let max_rate =
            valid_counter_max_rate(max_counter_rate_per_second).unwrap_or(COUNTER32_MODULUS);

        return plausible_counter_delta(wrapped, elapsed_seconds, Some(max_rate));
    }

    None
}

fn valid_counter_max_rate(max_counter_rate_per_second: Option<f64>) -> Option<f64> {
    max_counter_rate_per_second.filter(|rate| rate.is_finite() && *rate > 0.0)
}

pub(crate) fn plausible_counter_delta(
    delta: f64,
    elapsed_seconds: f64,
    max_rate: Option<f64>,
) -> Option<f64> {
    if elapsed_seconds <= 0.0 {
        return None;
    }

    if max_rate.is_some_and(|rate| delta / elapsed_seconds > rate) {
        return None;
    }

    Some(delta)
}
