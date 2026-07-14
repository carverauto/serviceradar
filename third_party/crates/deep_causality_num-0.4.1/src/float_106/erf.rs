/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Error function (`erf`) and complementary error function (`erfc`) for [`Float106`],
//! accurate to double-double precision (~31 decimal digits).
//!
//! Two representations are used, switched at `|x| = 1.5`:
//! * **Body** (`|x| < 1.5`): the all-positive Maclaurin series
//!   `erf(x) = (2/√π) e^{-x²} Σ_{n≥0} 2^n x^{2n+1} / (2n+1)!!` (Abramowitz & Stegun
//!   7.1.6). Every term is positive, so there is no cancellation.
//! * **Tail** (`|x| ≥ 1.5`): the continued fraction
//!   `erfc(x) = (e^{-x²}/√π) / (x + ½/(x + 1/(x + 3⁄2/(x + …))))` (A&S 7.1.14),
//!   evaluated with the modified Lentz algorithm. `erfc` is computed directly here,
//!   so the tail never forms `1 − erf(x)` and keeps full precision for large `x`.

use crate::Float;
use crate::Float106;

/// Magnitude at which the series body hands over to the continued-fraction tail.
const SERIES_TAIL_CROSSOVER: f64 = 1.5;

impl Float106 {
    /// The error function `erf(x)` at double-double precision.
    pub fn erf(self) -> Self {
        if self.is_nan() {
            return Self::nan();
        }
        if self.hi == 0.0 && self.lo == 0.0 {
            return Self::from_f64(0.0);
        }

        let ax = self.abs();
        let magnitude = if ax.hi < SERIES_TAIL_CROSSOVER {
            erf_series(ax)
        } else {
            // erf(|x|) = 1 − erfc(|x|); the subtraction loses only the few digits
            // by which erf falls short of 1, leaving the result well above f64.
            Self::from_f64(1.0) - erfc_tail(ax)
        };

        if self.is_sign_negative() {
            -magnitude
        } else {
            magnitude
        }
    }

    /// The complementary error function `erfc(x) = 1 − erf(x)` at double-double precision.
    pub fn erfc(self) -> Self {
        if self.is_nan() {
            return Self::nan();
        }

        // x ≤ 0: erf(x) ≤ 0, so `1 − erf(x)` is a sum of non-negatives — no cancellation.
        if self.hi <= 0.0 {
            return Self::from_f64(1.0) - self.erf();
        }

        if self.hi < SERIES_TAIL_CROSSOVER {
            // erfc < ~0.34 here, so `1 − erf` loses at most a fraction of a digit.
            Self::from_f64(1.0) - erf_series(self)
        } else {
            erfc_tail(self)
        }
    }
}

/// `2/√π` at double-double precision (derived from [`Float106::PI`] to avoid a hand-split literal).
#[inline]
fn two_over_sqrt_pi() -> Float106 {
    Float106::from_f64(2.0) / Float106::PI.sqrt()
}

/// `1/√π` at double-double precision.
#[inline]
fn inv_sqrt_pi() -> Float106 {
    Float106::from_f64(1.0) / Float106::PI.sqrt()
}

/// `erf(ax)` for `ax ≥ 0` via the all-positive series (Abramowitz & Stegun 7.1.6).
fn erf_series(ax: Float106) -> Float106 {
    let x2 = ax * ax;
    let two_x2 = x2 * Float106::from_f64(2.0);

    // n = 0 term is `x`; term_n = term_{n-1} · 2x² / (2n+1).
    let mut term = ax;
    let mut sum = ax;
    let mut n: u32 = 1;
    loop {
        term = term * two_x2 / Float106::from_f64((2 * n + 1) as f64);
        sum += term;
        if term.abs().hi < sum.abs().hi * 1e-34 {
            break;
        }
        n += 1;
        if n > 400 {
            break;
        }
    }

    two_over_sqrt_pi() * (-x2).exp() * sum
}

/// `erfc(x)` for `x ≥ 1.5` via the continued fraction (A&S 7.1.14), modified-Lentz evaluated.
fn erfc_tail(x: Float106) -> Float106 {
    // Guards against a zero denominator/numerator in the recurrence (Lentz's "tiny").
    let tiny = Float106::from_f64(1e-300);
    let one = Float106::from_f64(1.0);

    // Continued fraction f = x + a₁/(x + a₂/(x + …)), with aᵢ = i/2 and every bᵢ = x.
    let mut f = x;
    let mut c = f;
    let mut d = Float106::from_f64(0.0);
    let mut i: u32 = 1;
    loop {
        let a = Float106::from_f64(i as f64 * 0.5);

        d = x + a * d;
        if d.hi == 0.0 {
            d = tiny;
        }
        d = d.recip();

        c = x + a / c;
        if c.hi == 0.0 {
            c = tiny;
        }

        let delta = c * d;
        f *= delta;
        if (delta - one).abs().hi < 1e-32 {
            break;
        }
        i += 1;
        if i > 20_000 {
            break;
        }
    }

    let x2 = x * x;
    (-x2).exp() * inv_sqrt_pi() / f
}
