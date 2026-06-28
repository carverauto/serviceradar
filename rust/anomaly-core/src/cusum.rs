// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Two-sided tabular CUSUM (cumulative-sum) change detector for the slow drift /
//! leaks a point z-score structurally misses.
//!
//! A rolling z-score's mean *tracks* a gradual ramp, so a slow leak is absorbed into
//! the baseline and never trips (the proof harness measures this at 0/1 recall on the
//! drift/leak series). CUSUM instead accumulates a STANDARDIZED residual
//! `(x - target) / scale` against an **anchored** reference that is frozen when the
//! baseline first warms up — so a sustained drift away from the anchor accumulates
//! until it crosses the decision interval and alarms.
//!
//! Standard parameters: `k = 0.5` (slack / reference value, in sigma units) and
//! `h = 5.0` (decision interval) detect a sustained ~1-sigma shift. Expected time to
//! alarm for a persistent shift `δ` (in sigma) is ≈ `h / (δ - k)` samples.

/// A two-sided CUSUM accumulator.
#[derive(Clone, Copy, Debug)]
pub struct Cusum {
    /// Slack (reference value) in sigma units; only deviations beyond `k` accumulate.
    k: f64,
    /// Decision interval: an accumulator past `h` is an alarm.
    h: f64,
    /// Upper accumulator `S+` (catches an upward drift).
    pos: f64,
    /// Lower accumulator `S-` (catches a downward drift).
    neg: f64,
}

/// One CUSUM step: the (pre-reset) accumulators and whether either crossed `h`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CusumStep {
    pub pos: f64,
    pub neg: f64,
    pub alarm: bool,
}

impl Cusum {
    /// New accumulator with slack `k` and decision interval `h` (non-negative).
    pub fn new(k: f64, h: f64) -> Self {
        Self {
            k: k.max(0.0),
            h: h.max(0.0),
            pos: 0.0,
            neg: 0.0,
        }
    }

    /// Update with a standardized residual `(x - target) / scale`. Returns the
    /// (pre-reset) accumulators and whether either side crossed the decision interval.
    /// On alarm the accumulators reset to 0 so a continuing drift re-accumulates and
    /// re-alarms rather than latching. A non-finite input is a no-op.
    pub fn update(&mut self, standardized: f64) -> CusumStep {
        if !standardized.is_finite() {
            return CusumStep {
                pos: self.pos,
                neg: self.neg,
                alarm: false,
            };
        }
        self.pos = (self.pos + standardized - self.k).max(0.0);
        self.neg = (self.neg - standardized - self.k).max(0.0);
        let alarm = self.pos > self.h || self.neg > self.h;
        let step = CusumStep {
            pos: self.pos,
            neg: self.neg,
            alarm,
        };
        if alarm {
            self.pos = 0.0;
            self.neg = 0.0;
        }
        step
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stationary_noise_does_not_alarm() {
        let mut c = Cusum::new(0.5, 5.0);
        let mut any = false;
        // Alternating ±0.4 sigma: no sustained shift, so neither side should latch.
        for i in 0..1_000 {
            let z = if i % 2 == 0 { 0.4 } else { -0.4 };
            any |= c.update(z).alarm;
        }
        assert!(!any, "stationary noise must not alarm");
    }

    #[test]
    fn sustained_upward_drift_alarms_promptly() {
        let mut c = Cusum::new(0.5, 5.0);
        // A small persistent +0.6-sigma shift the point z-score would miss.
        let mut alarmed_at = None;
        for i in 0..500 {
            if c.update(0.6).alarm {
                alarmed_at = Some(i);
                break;
            }
        }
        let i = alarmed_at.expect("a sustained drift must eventually alarm");
        // ≈ h / (δ - k) = 5 / (0.6 - 0.5) = 50 steps; allow generous slack.
        assert!(i < 80, "drift should alarm within ~50 steps, alarmed at {i}");
    }

    #[test]
    fn sustained_downward_drift_alarms_on_neg_side() {
        let mut c = Cusum::new(0.5, 5.0);
        let mut alarmed = false;
        for _ in 0..500 {
            if c.update(-0.6).alarm {
                alarmed = true;
                break;
            }
        }
        assert!(alarmed, "a downward drift must alarm on the S- side");
    }
}
