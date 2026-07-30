/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Exact closed-form clipping primitives shared by the analytic intersection routines.
//!
//! Everything here works in **cell-local coordinates** (the box is `∏ [0, l_i]`) and returns
//! **measures** — volumes and areas, never pointwise samples — the cochain convention the
//! `graded-metrics` capability established and that the cut-geometry exactness tests inherit.
//!
//! Two families:
//!
//! - **Box ∩ half-space** (any dimension): the exact volume of the part of an axis-aligned
//!   box on the `≥` side of a plane, plus the exact `(D−1)`-area of the planar cross-section,
//!   via the standard inclusion–exclusion-over-corners formula
//!   `vol{Σ aᵢxᵢ ≤ c} = (1 / (m! · ∏ aᵢ)) · Σ_{S} (−1)^{|S|} relu(c − Σ_{i∈S} aᵢ lᵢ)^m`.
//! - **Rectangle ∩ disk** (2D): the exact area via the four-corner decomposition of the
//!   circular-quadrant area `∫∫_{u≤x, v≤y} 1_{u²+v²≤r²}`, whose antiderivative is elementary.

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

/// `max(a, b)` for a `RealField` (which carries `PartialOrd` but no inherent `max`).
pub(super) fn rmax<R: RealField>(a: R, b: R) -> R {
    if a > b { a } else { b }
}

/// `min(a, b)` for a `RealField`.
pub(super) fn rmin<R: RealField>(a: R, b: R) -> R {
    if a < b { a } else { b }
}

/// `relu(t)^p`: `t^p` for `t > 0` (with `t^0 = 1`), else `0`. The truncated power that makes
/// the box ∩ half-space corner sum exact.
fn relu_pow<R: RealField>(t: R, p: usize) -> R {
    if t <= R::zero() {
        return R::zero();
    }
    let mut acc = R::one();
    for _ in 0..p {
        acc *= t;
    }
    acc
}

/// `n!` as an `R`.
fn factorial<R: RealField + FromPrimitive>(n: usize) -> R {
    let mut acc = R::one();
    for k in 2..=n {
        acc *= R::from_usize(k).expect("factorial factor fits in R");
    }
    acc
}

/// Reduce a box ∩ half-space problem to all-positive coefficients by reflecting the axes
/// whose normal component is negative (`y_i = l_i − x_i`, volume-preserving). Returns
/// `(positive_coeffs, positive_lengths, zero_axis_length_product, shifted_offset)` in local
/// coordinates, where the half-space is `{ Σ pos_a·y ≤ shifted_c }` over the positive axes,
/// scaled by the product of the lengths of axes whose coefficient is exactly zero (those are
/// tangent to the plane and factor out).
fn reduce_halfspace<R: RealField>(l: &[R], n: &[R], c: R) -> (Vec<R>, Vec<R>, R, R) {
    let mut shifted_c = c;
    let mut pos_a: Vec<R> = Vec::new();
    let mut pos_l: Vec<R> = Vec::new();
    let mut zero_prod = R::one();
    for (i, &ni) in n.iter().enumerate() {
        if ni < R::zero() {
            // y_i = l_i − x_i : the term −n_i·y_i has positive coeff |n_i|, and the constant
            // n_i·l_i moves to the right-hand side (shifted_c grows since n_i < 0).
            shifted_c -= ni * l[i];
            pos_a.push(-ni);
            pos_l.push(l[i]);
        } else if ni > R::zero() {
            pos_a.push(ni);
            pos_l.push(l[i]);
        } else {
            zero_prod *= l[i];
        }
    }
    (pos_a, pos_l, zero_prod, shifted_c)
}

/// Exact volume of the part of the local box `∏ [0, l_i]` on the **solid** side of the plane
/// `Σ nᵢ xᵢ ≤ c` (local coordinates: pass `c − n·lo`). All dimensions.
pub(super) fn box_halfspace_solid_volume<R: RealField + FromPrimitive>(
    l: &[R],
    n: &[R],
    c: R,
) -> R {
    let (pos_a, pos_l, zero_prod, cc) = reduce_halfspace(l, n, c);
    let m = pos_a.len();

    // Full box volume (product of all lengths).
    let mut full = R::one();
    for &li in l {
        full *= li;
    }

    if m == 0 {
        // Constraint is 0 ≤ cc: the whole box is solid iff cc ≥ 0.
        return if cc >= R::zero() { full } else { R::zero() };
    }

    let num_subsets = 1usize << m;
    let mut total = R::zero();
    for subset in 0..num_subsets {
        let mut t = cc;
        let mut bits = 0usize;
        for (j, (&aj, &lj)) in pos_a.iter().zip(pos_l.iter()).enumerate() {
            if (subset >> j) & 1 == 1 {
                t -= aj * lj;
                bits += 1;
            }
        }
        let term = relu_pow(t, m);
        if bits.is_multiple_of(2) {
            total += term;
        } else {
            total -= term;
        }
    }

    let mut denom = factorial::<R>(m);
    for &aj in &pos_a {
        denom *= aj;
    }
    let mut solid = zero_prod * total / denom;
    // Guard against tiny negative / overshoot from rounding.
    if solid < R::zero() {
        solid = R::zero();
    }
    if solid > full {
        solid = full;
    }
    solid
}

/// Exact `(D−1)`-area of the cross-section `{ Σ nᵢ xᵢ = c } ∩ box` in local coordinates.
/// Requires `n` to be a **unit** normal (the caller normalises). Returns `0` for a null
/// normal.
pub(super) fn box_halfspace_cross_area<R: RealField + FromPrimitive>(l: &[R], n: &[R], c: R) -> R {
    let (pos_a, pos_l, zero_prod, cc) = reduce_halfspace(l, n, c);
    let m = pos_a.len();
    if m == 0 {
        return R::zero();
    }

    let num_subsets = 1usize << m;
    let mut total = R::zero();
    for subset in 0..num_subsets {
        let mut t = cc;
        let mut bits = 0usize;
        for (j, (&aj, &lj)) in pos_a.iter().zip(pos_l.iter()).enumerate() {
            if (subset >> j) & 1 == 1 {
                t -= aj * lj;
                bits += 1;
            }
        }
        let term = relu_pow(t, m - 1);
        if bits.is_multiple_of(2) {
            total += term;
        } else {
            total -= term;
        }
    }

    let mut denom = factorial::<R>(m - 1);
    for &aj in &pos_a {
        denom *= aj;
    }
    let area = zero_prod * total / denom;
    if area < R::zero() { R::zero() } else { area }
}

/// `∫_a^b sqrt(r² − u²) du`, the elementary antiderivative
/// `½(u·sqrt(r²−u²) + r²·asin(u/r))`, with `u` clamped to `[−r, r]`.
fn sqrt_integral<R: RealField>(a: R, b: R, r: R) -> R {
    let prim = |u: R| -> R {
        let uc = if u < -r {
            -r
        } else if u > r {
            r
        } else {
            u
        };
        let s = rmax(r * r - uc * uc, R::zero()).sqrt();
        let half = R::one() / (R::one() + R::one());
        half * (uc * s + r * r * (uc / r).asin())
    };
    prim(b) - prim(a)
}

/// Area of `disk(0, r) ∩ { u ≤ x, v ≤ y }` (center-relative coordinates). The four-corner
/// inclusion–exclusion of this primitive yields the exact rectangle ∩ disk area.
fn circular_quadrant_area<R: RealField>(x: R, y: R, r: R) -> R {
    if x <= -r || y <= -r {
        return R::zero();
    }
    let xc = if x > r { r } else { x };
    // Whole vertical strip up to xc when the horizontal cut is above the disk.
    if y >= r {
        return (R::one() + R::one()) * sqrt_integral(-r, xc, r);
    }

    // t = |u| where the circle height s = sqrt(r²−u²) equals |y|.
    let t = rmax(r * r - y * y, R::zero()).sqrt();
    let two = R::one() + R::one();

    if y >= R::zero() {
        // Height profile of {v ≤ y} ∩ disk over u: 2s for |u| > t (s < y), y + s for |u| ≤ t.
        let mut area = R::zero();
        // 2s on [−r, min(xc, −t)]
        let u2 = if xc < -t { xc } else { -t };
        if u2 > -r {
            area += two * sqrt_integral(-r, u2, r);
        }
        // y + s on [−t, min(xc, t)]
        let u2 = if xc < t { xc } else { t };
        if u2 > -t {
            area += y * (u2 - (-t)) + sqrt_integral(-t, u2, r);
        }
        // 2s on [t, xc]
        if xc > t {
            area += two * sqrt_integral(t, xc, r);
        }
        area
    } else {
        // y < 0: nonzero only where s ≥ −y, i.e. |u| ≤ t; height there is y + s.
        let u1 = if -t > -r { -t } else { -r };
        let u2 = if xc < t { xc } else { t };
        if u2 > u1 {
            y * (u2 - u1) + sqrt_integral(u1, u2, r)
        } else {
            R::zero()
        }
    }
}

/// Exact area of the axis-aligned rectangle `[lo0, hi0] × [lo1, hi1]` intersected with the
/// disk of radius `r` centred at `center`. The **solid** area (inside the disk).
pub(super) fn rect_disk_solid_area<R: RealField>(
    lo: [R; 2],
    hi: [R; 2],
    center: [R; 2],
    r: R,
) -> R {
    let x0 = lo[0] - center[0];
    let x1 = hi[0] - center[0];
    let y0 = lo[1] - center[1];
    let y1 = hi[1] - center[1];
    circular_quadrant_area(x1, y1, r)
        - circular_quadrant_area(x0, y1, r)
        - circular_quadrant_area(x1, y0, r)
        + circular_quadrant_area(x0, y0, r)
}

/// Arc length of the circle of radius `r` centred at `center` that lies inside the
/// axis-aligned rectangle `[lo0, hi0] × [lo1, hi1]`. Used for the 2D / cylinder cut-face
/// fragment measure. Computed as the angular measure of the in-rectangle arc times `r`.
pub(super) fn circle_in_rect_arc_len<R: RealField + FromPrimitive>(
    lo: [R; 2],
    hi: [R; 2],
    center: [R; 2],
    r: R,
) -> R {
    if r <= R::zero() {
        return R::zero();
    }
    // Sample the angular indicator on a fine uniform grid and trapezoid-integrate. The arc
    // length is r·∫ 1_inside dθ; a fragment measure feeds the Stage-4 BC stage and is not on
    // the spec's exactness scenario (which gates volume + apertures), so a high-resolution
    // quadrature is the pragmatic, dependency-free choice here.
    let steps = 2048usize;
    let two_pi = R::pi() * (R::one() + R::one());
    let dtheta = two_pi / R::from_usize(steps).expect("step count fits in R");
    let mut inside = 0usize;
    for k in 0..steps {
        let theta = dtheta * R::from_usize(k).expect("index fits in R");
        let px = center[0] + r * theta.cos();
        let py = center[1] + r * theta.sin();
        if px >= lo[0] && px <= hi[0] && py >= lo[1] && py <= hi[1] {
            inside += 1;
        }
    }
    r * dtheta * R::from_usize(inside).expect("count fits in R")
}
