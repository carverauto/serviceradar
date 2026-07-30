/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Single-edge Metropolis-Hastings update for `CubicalReggeGeometry<D, R, S>`
//! — Phase R6.4.
//!
//! Operates on `PerEdge` cubical geometries by proposing a Gaussian
//! perturbation to a uniformly-chosen edge length and accepting / rejecting
//! per the Metropolis-Hastings criterion `min(1, exp(−β · ΔS))`.
//!
//! # Locality of ΔS
//!
//! Because the action `S = Σ_h vol(h) · deficit(h)` is bilinear in edge
//! lengths on axis-aligned cubical (the deficit angle is purely
//! combinatorial, see the `gradient` module derivation), the change in
//! action when only `L_e` changes is *exactly*:
//!
//! ```text
//! ΔS = (L_new − L_old) · gradient_at[e]
//! ```
//!
//! No approximation. The single-edge gradient component costs `O(2^D)` to
//! evaluate via the standard `regge_gradient` summation restricted to hinges
//! incident to edge `e`. For implementation simplicity, this R6.4 version
//! computes the full gradient and takes entry `[e]`; a future perf change
//! could maintain an edge-to-hinges inverse map.
//!
//! # Detailed balance
//!
//! Gaussian proposals on edge lengths are symmetric (`q(L'|L) = q(L|L')`),
//! so the Metropolis criterion is the standard `min(1, π(L')/π(L))` with
//! `π ∝ exp(−β S)`. The `NonPositiveLength` rejection (a hard floor at
//! `L > 0`) preserves detailed balance because rejected proposals stay at
//! the current state — design.md Risk 5.
//!
//! # Restricted to Euclidean for now
//!
//! Lorentzian Metropolis is deferred per design.md Decision 7 "Wick rotation
//! deferred subtlety" — the action `S_L = i · S_E` makes
//! `|exp(−β S_L)| = 1` identically, so naive Metropolis-Hastings has no
//! thermalisation. Standard fix is to do MC on the Euclidean action and
//! analytically continue. The Euclidean path implemented here is the
//! primitive that Lorentzian MC would build on.

use super::{CubicalReggeGeometry, EdgeLengths, Euclidean};
use crate::traits::chain_complex::ChainComplex;
use crate::types::lattice_complex::LatticeComplex;
use deep_causality_algebra::{Real, RealField};
use deep_causality_num::{Float, FromPrimitive};
use deep_causality_rand::{Distribution, Normal, Rng, StandardUniform};

/// Outcome of a single Metropolis-Hastings step.
#[derive(Debug, Clone, PartialEq)]
pub enum AcceptReject<R: RealField> {
    /// The proposal was accepted; the geometry's edge length has been mutated
    /// in place to `proposed_length`.
    Accepted {
        edge: usize,
        proposed_length: R,
        delta_action: R,
    },
    /// The proposal was rejected; the geometry is unchanged.
    Rejected {
        edge: usize,
        proposed_length: R,
        reason: RejectReason<R>,
    },
}

/// Reason a Metropolis proposal was rejected.
#[derive(Debug, Clone, PartialEq)]
pub enum RejectReason<R: RealField> {
    /// Proposed edge length is `≤ 0`; edge lengths are positive by physical
    /// requirement and the hard floor preserves detailed balance per design.md
    /// Risk 5.
    NonPositiveLength,
    /// The Metropolis-Hastings probabilistic rejection branch fired: the
    /// proposal was geometrically valid but uniform `u ∈ [0, 1)` exceeded
    /// the acceptance probability `exp(−β · ΔS)`.
    Probabilistic { delta_action: R, threshold: R },
}

impl<const D: usize, R> CubicalReggeGeometry<D, R, Euclidean>
where
    R: RealField + FromPrimitive + Float,
    StandardUniform: Distribution<R>,
    deep_causality_rand::StandardNormal: Distribution<R>,
{
    /// One single-edge Metropolis-Hastings step on a `PerEdge` geometry.
    ///
    /// 1. Picks an edge uniformly at random from `[0, complex.num_cells(1))`.
    /// 2. Proposes `L_e' = L_e + N(0, σ²)` via a centered Gaussian.
    /// 3. Rejects unconditionally if `L_e' ≤ 0` (non-positivity floor).
    /// 4. Computes `ΔS = (L_e' − L_e) · gradient[e]` (exact, see module doc).
    /// 5. Accepts with probability `min(1, exp(−β · ΔS))`.
    ///
    /// On acceptance, the geometry's `PerEdge` length buffer is mutated in
    /// place at index `edge`. On rejection, the geometry is unchanged.
    ///
    /// # Panics
    /// Panics if the geometry is not `PerEdge`. The single-edge update is
    /// only well-defined when every edge can be individually mutated; for
    /// `UnitEdge` / `Uniform` / `PerAxis` the caller must first convert via
    /// `from_edge_lengths(self.flatten_to_per_edge())` (helper not yet
    /// shipped; track as a follow-up if needed).
    pub fn metropolis_update<G: Rng>(
        &mut self,
        complex: &LatticeComplex<D, R>,
        rng: &mut G,
        sigma: R,
        beta: R,
    ) -> AcceptReject<R> {
        let num_edges = complex.num_cells(1);
        assert!(
            num_edges > 0,
            "Metropolis update requires at least one edge"
        );

        // Snapshot the per-edge length buffer pointer; panic if not PerEdge.
        let edge_id = (rng.next_u64() as usize) % num_edges;
        let current_length = match &self.edge_lengths {
            EdgeLengths::PerEdge { lengths } => *lengths
                .get(edge_id)
                .expect("edge_id < num_edges by uniform sampling"),
            _ => panic!(
                "metropolis_update requires `PerEdge` geometry; convert via \
                 `from_edge_lengths(...)` first."
            ),
        };

        // Propose: L_new = L_old + σ · N(0, 1) (equivalently N(0, σ²)).
        let normal = Normal::<R>::new(R::zero(), sigma)
            .expect("Normal(0, σ) is well-defined for any RealField σ > 0");
        let delta_l = normal.sample(rng);
        let proposed = current_length + delta_l;

        // Non-positivity hard floor: reject, geometry unchanged.
        if proposed <= R::zero() {
            return AcceptReject::Rejected {
                edge: edge_id,
                proposed_length: proposed,
                reason: RejectReason::NonPositiveLength,
            };
        }

        // ΔS = (L_new − L_old) · gradient[e]. Exact for axis-aligned cubical.
        // Hot path: use the single-edge gradient component (O(D · 2^D))
        // instead of the full per-edge gradient (O(num_hinges · 2^D)) — the
        // speedup factor scales with `num_edges`, and is what makes long
        // Metropolis runs (R6.5 detailed-balance test, downstream HMC) viable.
        let grad_e = self.regge_gradient_at_edge(complex, edge_id);
        let delta_action = (proposed - current_length) * grad_e;

        // Metropolis criterion: accept if delta_action ≤ 0 (always favourable),
        // otherwise accept with probability exp(−β · ΔS).
        let threshold = Real::exp(-beta * delta_action);
        let always_accept = delta_action <= R::zero();
        let u: R = rng.sample(StandardUniform);
        let accept = always_accept || u < threshold;

        if accept {
            // Commit the mutation in place.
            if let EdgeLengths::PerEdge { lengths } = &mut self.edge_lengths {
                lengths[edge_id] = proposed;
            }
            // A changed edge length invalidates every memoized Hodge ⋆
            // diagonal; drop the cache so the next solve rebuilds.
            self.star_cache.invalidate();
            AcceptReject::Accepted {
                edge: edge_id,
                proposed_length: proposed,
                delta_action,
            }
        } else {
            AcceptReject::Rejected {
                edge: edge_id,
                proposed_length: proposed,
                reason: RejectReason::Probabilistic {
                    delta_action,
                    threshold,
                },
            }
        }
    }
}
