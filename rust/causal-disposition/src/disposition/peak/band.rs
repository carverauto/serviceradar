// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The Uncertainty-Aware Shrinkage Band decision — an O(1) scalar function from a
//! `(PeakRow, PeakConfig)` to a [`PeakDisposition`].
//!
//! False-suppress (silencing a real anomaly) is the cardinal error, so every
//! uncertain path resolves to `PassThrough` or `Escalate`, never `Suppress`. The
//! enforced invariants (proved by `tests.rs`):
//! - **I1 two-sided** — a downward excursion outside the outer band escalates.
//! - **I2 poison-bounded inner band** — `s_inner = min(s_cell, cap·s_prior)`.
//! - **I4 ceiling-proximity** — no upward headroom ⇒ pass through.
//! - **I5 over-dispersion** — `s_cell > d·s_prior` ⇒ pass through.
//! - **I6 cold** — `n < n_min` ⇒ pass through.
//! - **I8 asymmetry** — uncertainty only ever widens toward pass-through/escalate.
//!
//! (I3 localized prior is enforced in SQL; I7 confirm-slot non-reset lives in the
//! `CausalFlow`, not this pure kernel.)

use super::types::{PassReason, PeakConfig, PeakDisposition, PeakRow};

/// Decide the disposition of one spike peak against its `(series, hod)` cell.
pub fn decide(row: &PeakRow, config: &PeakConfig) -> PeakDisposition {
    // Non-finite inputs never suppress.
    if !row.peak.is_finite() || !row.cell_center.is_finite() {
        return PeakDisposition::PassThrough {
            reason: PassReason::NonFinite,
        };
    }

    // I6 — cold cell: not enough samples to trust any band.
    if row.n < config.n_min {
        return PeakDisposition::PassThrough {
            reason: PassReason::Cold,
        };
    }

    let s_cell = sanitize_scale(row.cell_scale);
    let s_prior = sanitize_scale(row.prior_scale);

    // I5 — over-dispersion: the cell is far wider than its localized class prior,
    // i.e. it looks poisoned/degenerate. Refuse to suppress.
    if s_prior > 0.0 && s_cell > config.d_overdispersion * s_prior {
        return PeakDisposition::PassThrough {
            reason: PassReason::OverDispersed,
        };
    }

    // Scale selection. The SUPPRESSION (inner) band is bounded ABOVE by the
    // localized prior (I2): a poisoned/thin cell can never widen suppression
    // beyond `cap·s_prior`. The ESCALATION (outer) band takes the wider scale,
    // because wider escalation is always safe under the asymmetry.
    let cap_prior = config.cap * s_prior;
    let mut s_inner = if cap_prior > 0.0 {
        s_cell.min(cap_prior)
    } else {
        s_cell
    };
    let mut s_outer = s_cell.max(s_prior);

    // Degenerate-scale floor — applied ONLY when a scale is ~0 (a flat cell), so a
    // genuinely tight series keeps its small, real scale and is never blinded.
    if s_inner < config.scale_floor {
        s_inner = config.scale_floor;
    }
    if s_outer < config.scale_floor {
        s_outer = config.scale_floor;
    }

    // Sigma-relative low-`n` inflation: widens with the series' OWN scale and
    // decays to 1 as n grows. No additive raw floor.
    let k_n = 1.0 + config.a / (row.n.max(1) as f64).sqrt();
    let band_inner = config.z_sup * s_inner * k_n;
    let band_outer = config.z_esc * s_outer * k_n;

    // I4 — ceiling-proximity: if the inner band would reach the ceiling there is no
    // upward headroom to discriminate a real spike, so refuse to suppress.
    if config
        .ceiling
        .is_some_and(|ceiling| row.q95 + band_inner >= ceiling)
    {
        return PeakDisposition::PassThrough {
            reason: PassReason::CeilingProximity,
        };
    }

    let c = row.cell_center;
    let inner_lo = c - band_inner;
    let inner_hi = c + band_inner;
    let outer_lo = c - band_outer;
    let outer_hi = c + band_outer;

    // One-sided residual magnitude (in inner-scale units) for the surfaced score.
    let score = (row.peak - c).abs() / (s_inner * k_n).max(f64::EPSILON);

    if row.peak >= inner_lo && row.peak <= inner_hi {
        // Within the poison-bounded normal range — suppress.
        PeakDisposition::Suppress
    } else if row.peak > outer_hi || row.peak < outer_lo {
        // I1 — clearly off-profile in EITHER direction — escalate.
        PeakDisposition::Escalate { score }
    } else {
        // The annulus between the bands — keep visible, do not silence.
        PeakDisposition::Downgrade { score }
    }
}

/// Clamp a scale to a finite, non-negative value (a non-finite or negative scale
/// from upstream collapses to 0, which the floors then handle).
fn sanitize_scale(s: f64) -> f64 {
    if s.is_finite() && s > 0.0 { s } else { 0.0 }
}
