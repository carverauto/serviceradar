/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Graded (variable-spacing) metric constructors — CFD rung R1 of
//! `variable-grid-geometry.md`.
//!
//! A graded mesh is a *metric state*, not a data structure: it is a `PerEdge` edge-length
//! assignment on an unchanged [`LatticeComplex`], so `d∘d = 0`, the discrete Stokes
//! theorem, and the divergence-free-by-construction property of the Leray projection hold
//! for *any* grading — only accuracy order is at stake, never structure (the headline
//! exactness gate). These constructors evaluate an analytic per-axis stretching law at each
//! edge and delegate to [`CubicalReggeGeometry::from_edge_lengths`]; the operators and Hodge
//! star already dispatch the `PerEdge` variant, so nothing downstream changes.
//!
//! Following the num-crate paradigm, the surface is bound on `RealField + FromPrimitive`
//! (analytic ops + lifting `usize` lattice indices into `R`) — never on the bit-level
//! `Float` trait — so a future scalar type rides these constructors unchanged.

use super::{CubicalReggeGeometry, Euclidean};
use crate::types::lattice_complex::LatticeComplex;
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

impl<const D: usize, R: RealField + FromPrimitive> CubicalReggeGeometry<D, R, Euclidean> {
    /// Geometric (constant growth-ratio) graded metric.
    ///
    /// The edge at integer position `pos` along axis `a` is assigned length
    /// `base[a] · ratio[a]^pos`; `ratio[a] == 1` leaves axis `a` uniform at spacing
    /// `base[a]`. This is the standard near-wall family — growth ratios in the
    /// `1.05..1.3` range are typical industrial practice. Produces a `PerEdge` geometry
    /// over `complex` (edge lengths laid out in `iter_cells(1)` order).
    pub fn from_graded_geometric(
        complex: &LatticeComplex<D, R>,
        base: [R; D],
        ratio: [R; D],
    ) -> Self {
        let mut lengths = Vec::new();
        for cell in complex.iter_cells(1) {
            // An edge has exactly one orientation bit set; that bit is its axis.
            let axis = cell.orientation().trailing_zeros() as usize;
            let pos = cell.position()[axis];
            let exponent = R::from_usize(pos).expect("lattice position must fit in R");
            lengths.push(base[axis] * ratio[axis].powf(exponent));
        }
        Self::from_edge_lengths(lengths)
    }

    /// Two-sided hyperbolic-tangent (Vinokur-style) graded metric clustering toward both
    /// ends of a single wall-normal `axis` over a domain of length `total_length`.
    ///
    /// `beta` is the clustering strength; `beta → 0` recovers uniform spacing. The graded
    /// axis is intended to be **open** (wall-bounded); all other axes are left uniform at
    /// unit spacing. Produces a `PerEdge` geometry over `complex`.
    pub fn from_graded_tanh(
        complex: &LatticeComplex<D, R>,
        axis: usize,
        total_length: R,
        beta: R,
    ) -> Self {
        let v = complex.shape()[axis];
        let nodes = tanh_nodes::<R>(v, total_length, beta);

        let mut lengths = Vec::new();
        for cell in complex.iter_cells(1) {
            let a = cell.orientation().trailing_zeros() as usize;
            if a == axis && v >= 2 {
                let pos = cell.position()[axis];
                // Edge `pos` spans vertices `pos..pos+1`. Clamp the forward index so a
                // wrapped edge on a (non-physical) periodic graded axis reuses the last
                // spacing instead of indexing out of bounds.
                let hi = (pos + 1).min(v - 1);
                let lo = hi - 1;
                lengths.push(nodes[hi] - nodes[lo]);
            } else {
                lengths.push(R::one());
            }
        }
        Self::from_edge_lengths(lengths)
    }
}

/// Physical node coordinates `x_j = total_length · s_j` along a graded axis with `v`
/// vertex layers, using the two-sided tanh map
/// `s_j = ½ (1 + tanh(β(ξ_j − ½)) / tanh(β/2))`, `ξ_j = j / (v−1)`.
/// Degenerates to uniform spacing as `β → 0` (where `tanh(β/2) → 0`).
fn tanh_nodes<R: RealField + FromPrimitive>(v: usize, total_length: R, beta: R) -> Vec<R> {
    if v < 2 {
        return vec![R::zero(); v];
    }
    let half = R::from_f64(0.5).expect("0.5 representable");
    let one = R::one();
    let denom = (beta * half).tanh();
    // β → 0 makes the denominator vanish; fall back to a uniform parameter.
    let uniform = denom.abs() < R::epsilon();
    let n_minus_1 = R::from_usize(v - 1).expect("v-1 fits in R");

    (0..v)
        .map(|j| {
            let xi = R::from_usize(j).expect("index fits in R") / n_minus_1;
            let s = if uniform {
                xi
            } else {
                half * (one + (beta * (xi - half)).tanh() / denom)
            };
            total_length * s
        })
        .collect()
}
