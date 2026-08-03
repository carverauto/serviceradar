/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Regge-action gradient for `CubicalReggeGeometry<D, R, S>` — Phase R6.
//!
//! Closed form on axis-aligned cubical lattices. The dihedral angle is
//! identically `π/2` regardless of edge lengths (see the `curvature` module
//! header), so the deficit angle `(4 − n) · π/2` carries no edge-length
//! sensitivity — `n` is the incident top-cube count, a purely combinatorial
//! quantity. All edge-length sensitivity of the action flows through the
//! hinge volume `vol(h)`:
//!
//! ```text
//! S_R = Σ_h  vol(h) · deficit(h)
//!
//! ∂S_R/∂L_i = Σ_{h : edge i is in h's axes}  (∂vol(h)/∂L_i) · deficit(h)
//!           = Σ_{h : edge i is in h's axes}  (vol(h) / L_i) · deficit(h)
//! ```
//!
//! by the product rule (`∂(L_a · L_b · …)/∂L_i = (L_a · L_b · …) / L_i` if
//! `L_i` is one of the factors; `0` otherwise).
//!
//! ## Per-dimension behaviour
//!
//! - **D = 2** — hinges are vertices (0-cells) with empty orientation; the
//!   hinge volume is the empty product `R::one()`, so `∂vol/∂L_i = 0` for
//!   every edge and the gradient is identically zero. The 2D action depends
//!   only on the deficit pattern, not on edge lengths.
//! - **D = 3** — hinges are edges (1-cells); each hinge contributes to
//!   exactly one edge (itself) with `∂vol/∂L_h = 1`. So
//!   `gradient[edge_id] = deficit(edge_id)`.
//! - **D = 4** — hinges are squares (2-cells); each square has two axes in
//!   its orientation and contributes to two edges. The contribution to each
//!   edge is the *other* axis length times the deficit.
//!
//! ## Locality
//!
//! Each edge `i`'s gradient entry depends only on the O(2^(D−1)) hinges that
//! contain edge `i` (a hinge can contain an edge only if the hinge's
//! orientation includes the edge's axis, and the hinge is one of the
//! finitely many (D−2)-cells incident to that edge). The total cost is
//! `O(num_edges · 2^D)` per gradient evaluation. This locality is what makes
//! the R6.4 single-edge Metropolis update efficient: `ΔS` from perturbing
//! one edge is `gradient[i] · δL_i + O(δL_i²)`, evaluable in O(2^D).
//!
//! ## Verification (R6.3)
//!
//! Property tests in
//! `tests/types/cubical_regge_geometry/regge_gradient_tests.rs` confirm the
//! closed form against a central finite-difference estimate
//! `(S(L + ε·δ_i) − S(L − ε·δ_i)) / (2ε)` to ~5 significant figures, and
//! verify the unit-edge equilibrium claim that the unit-length configuration
//! is a stationary point only when there is no boundary curvature.

use super::{CubicalReggeGeometry, Euclidean, Lorentzian, SignatureMarker};
use crate::traits::chain_complex::ChainComplex;
use crate::types::lattice_complex::LatticeComplex;
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_num_complex::Complex;

impl<const D: usize, R: RealField + FromPrimitive, S: SignatureMarker>
    CubicalReggeGeometry<D, R, S>
{
    /// Real-valued hinge gradient sum, shared by the Euclidean and Lorentzian
    /// variants. Returns `∂(hinge_action_sum)/∂L_i` for every edge `i` in the
    /// lattice's canonical `iter_cells(1)` ordering.
    ///
    /// The deficit angle is signature-independent (purely combinatorial on
    /// axis-aligned cubical), so the per-edge derivative does not depend on
    /// `S`. The Euclidean wrapper returns this directly; the Lorentzian
    /// wrapper multiplies by `i` per the Wick-rotated action convention.
    pub(super) fn hinge_gradient_sum(&self, complex: &LatticeComplex<D, R>) -> Vec<R> {
        let num_edges = complex.num_cells(1);
        let mut grad = vec![R::zero(); num_edges];

        if D < 2 {
            return grad;
        }

        for (hinge_id, hinge) in complex.iter_cells(D - 2).enumerate() {
            let deficit = self.deficit_angle(complex, hinge_id);
            if deficit == R::zero() {
                continue;
            }
            let vol = self.cell_volume(complex, &hinge);
            let position = *hinge.position();
            let orientation = hinge.orientation();

            // Distribute (vol/L_axis) · deficit to each edge in the hinge's axes.
            for axis in 0..D {
                if (orientation & (1u32 << axis)) != 0 {
                    let edge_length = self.axis_length_at_position(complex, position, axis);
                    if edge_length == R::zero() {
                        continue;
                    }
                    let edge_id = complex.edge_index(position, axis);
                    if edge_id < num_edges {
                        grad[edge_id] += (vol / edge_length) * deficit;
                    }
                }
            }
        }

        grad
    }

    /// Single-edge gradient: `∂(hinge_action_sum)/∂L_e` for one edge only.
    ///
    /// Enumerates only the (D−2)-hinges that contain edge `e`. Cost is
    /// `O(D · 2^D)` per call — independent of `num_edges` and `num_hinges`.
    /// This is the hot path used by `metropolis_update` for single-edge
    /// updates, where computing the full per-edge gradient (then indexing
    /// one entry) would be `O(num_hinges · 2^D)` per Metropolis step —
    /// hugely wasteful when `num_hinges ≈ num_edges`.
    ///
    /// # Hinge enumeration (axis-aligned cubical)
    ///
    /// For an edge at position `p` along axis `a`, the (D−2)-cells containing
    /// it are characterised by:
    /// - orientation `o` with `a ∈ o` and `|o| = D − 2`;
    /// - position `q` with `q[a] = p[a]`;
    /// - for each `b ∈ o \ {a}`: `q[b] ∈ {p[b], p[b] − 1}` (the cell extends
    ///   one unit in axis `b`, must straddle `p[b]`);
    /// - for each `c ∉ o`: `q[c] = p[c]`.
    ///
    /// Total candidate hinges: `C(D−1, D−3) · 2^(D−2)` = `O(D · 2^D)`. For
    /// D=3 this is 1 hinge (the edge itself, deficit-only contribution); for
    /// D=4 it is 6 hinges.
    ///
    /// Returns `R::zero()` for `D < 2` (no hinges exist) or out-of-range
    /// `edge_id`.
    pub fn hinge_gradient_at_edge(&self, complex: &LatticeComplex<D, R>, edge_id: usize) -> R {
        if D < 2 {
            return R::zero();
        }
        let Some((edge_position, edge_axis)) = complex.edge_id_to_position_axis(edge_id) else {
            return R::zero();
        };
        let edge_length = self.axis_length_at_position(complex, edge_position, edge_axis);
        if edge_length == R::zero() {
            return R::zero();
        }

        let all_axes_mask: u32 = if D >= 32 { u32::MAX } else { (1u32 << D) - 1 };
        let edge_bit = 1u32 << edge_axis;
        let mut total = R::zero();
        let target_hinge_grade = D - 2;
        let shape = complex.shape();
        let periodic = complex.periodic();

        // Iterate over every other-axis orientation that, together with the
        // edge axis, forms a valid hinge orientation of size D-2.
        // For D=2: target_hinge_grade = 0 ⇒ hinges have empty orientation,
        //   no axes can include the edge axis ⇒ no contribution. Skip.
        // For D=3: target_hinge_grade = 1, other_axes_count = 0 ⇒ exactly
        //   one orientation `{a}`, no extra-axis positional choices.
        // For D≥4: choose `other_axes_count` axes from the D−1 non-edge axes;
        //   for each choice, enumerate 2^other_axes_count position offsets.
        if target_hinge_grade == 0 {
            return R::zero();
        }

        for orientation_candidate in 0..(1u32 << D) {
            if (orientation_candidate & edge_bit) == 0 {
                continue;
            }
            if orientation_candidate.count_ones() as usize != target_hinge_grade {
                continue;
            }
            let other_axes_mask = (orientation_candidate & !edge_bit) & all_axes_mask;
            // Pack the (at most D) other axes into a stack array; avoids
            // any heap allocation in the hot path.
            let mut other_axes: [usize; 32] = [0; 32];
            let mut other_axes_len: usize = 0;
            for axis in 0..D {
                if (other_axes_mask & (1u32 << axis)) != 0 {
                    other_axes[other_axes_len] = axis;
                    other_axes_len += 1;
                }
            }

            // 2^|other_axes| corner positions: each other-axis can have
            // q[b] ∈ {p[b], p[b]-1}.
            for shift_mask in 0..(1u32 << other_axes_len as u32) {
                let mut position = edge_position;
                let mut valid = true;
                for (bit_idx, &axis_b) in other_axes.iter().take(other_axes_len).enumerate() {
                    let shift_down = (shift_mask >> bit_idx) & 1 == 1;
                    let p_b = edge_position[axis_b];
                    let new_b = if shift_down {
                        if p_b == 0 {
                            if periodic[axis_b] {
                                shape[axis_b].saturating_sub(1)
                            } else {
                                valid = false;
                                break;
                            }
                        } else {
                            p_b - 1
                        }
                    } else {
                        if !periodic[axis_b] && p_b >= shape[axis_b].saturating_sub(1) {
                            // Hinge would extend past lattice on axis b.
                            valid = false;
                            break;
                        }
                        p_b
                    };
                    position[axis_b] = new_b;
                }
                if !valid {
                    continue;
                }

                // Build the hinge cell and find its id in `iter_cells(D-2)`.
                let hinge_cell = crate::types::lattice_complex::LatticeCell::new(
                    position,
                    orientation_candidate,
                );
                let Some(hinge_id) = complex
                    .cells(target_hinge_grade)
                    .position(|c| c == hinge_cell)
                else {
                    continue;
                };
                let deficit = self.deficit_angle(complex, hinge_id);
                if deficit == R::zero() {
                    continue;
                }
                let vol = self.cell_volume(complex, &hinge_cell);
                total += (vol / edge_length) * deficit;
            }
        }

        total
    }
}

/// Euclidean-only `regge_gradient` returning `Vec<R>`.
impl<const D: usize, R: RealField + FromPrimitive> CubicalReggeGeometry<D, R, Euclidean> {
    /// Closed-form gradient of the discrete Regge action with respect to each
    /// edge length, indexed by `edge_index` in the lattice's canonical
    /// `iter_cells(1)` order.
    ///
    /// Result length always equals `complex.num_cells(1)`. For `D < 2` the
    /// vector is all zeros (the action is empty). For `D = 2` the vector is
    /// also all zeros (hinges are vertices with empty product volume = 1).
    /// For `D ≥ 3` the entries are generically non-zero on open lattices
    /// (where boundary hinges carry deficit) and zero on periodic lattices
    /// (where every hinge has deficit 0).
    pub fn regge_gradient(&self, complex: &LatticeComplex<D, R>) -> Vec<R> {
        self.hinge_gradient_sum(complex)
    }

    /// Single-edge `∂S_R/∂L_e` — the hot path for `metropolis_update` and
    /// any HMC-style sampler that needs one component at a time. O(D · 2^D)
    /// per call, *independent of `num_edges`*.
    ///
    /// Numerically identical to `self.regge_gradient(complex)[edge_id]` but
    /// without the full-vector allocation or the walk over hinges that don't
    /// contain `edge_id`. Speedup factor on the order of `num_hinges` per
    /// single-component lookup.
    pub fn regge_gradient_at_edge(&self, complex: &LatticeComplex<D, R>, edge_id: usize) -> R {
        self.hinge_gradient_at_edge(complex, edge_id)
    }
}

/// Lorentzian-only `regge_gradient` returning `Vec<Complex<R>>`.
///
/// Under the Wick-rotated convention `S_L = i · S_E` (see
/// `regge_action_lorentzian`), the Lorentzian gradient is also purely
/// imaginary: `∂S_L/∂L_i = i · ∂S_E/∂L_i`. Every returned entry has
/// `re = 0` and `im = ∂(hinge_action_sum)/∂L_i`.
impl<const D: usize, R: RealField + FromPrimitive> CubicalReggeGeometry<D, R, Lorentzian> {
    /// Closed-form gradient of the discrete Lorentzian Regge action with
    /// respect to each edge length, indexed by `edge_index`. Purely imaginary
    /// under the chosen Wick-rotation convention.
    pub fn regge_gradient(&self, complex: &LatticeComplex<D, R>) -> Vec<Complex<R>> {
        self.hinge_gradient_sum(complex)
            .into_iter()
            .map(|im| Complex { re: R::zero(), im })
            .collect()
    }

    /// Single-edge Lorentzian gradient component. Same O(D · 2^D) locality
    /// as the Euclidean variant; purely imaginary by construction.
    pub fn regge_gradient_at_edge(
        &self,
        complex: &LatticeComplex<D, R>,
        edge_id: usize,
    ) -> Complex<R> {
        Complex {
            re: R::zero(),
            im: self.hinge_gradient_at_edge(complex, edge_id),
        }
    }
}
