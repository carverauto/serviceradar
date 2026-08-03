/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Discrete interior product (contraction) on cubical lattice cochains.
//!
//! Implements Hirani's star–wedge formula (Discrete Exterior Calculus, Caltech
//! 2003, §8): for a 1-form `X♭` and a k-form `ω` on a D-lattice,
//!
//! ```text
//! i_X ω = (−1)^{k(D−k)} ⋆(⋆ω ∧ X♭)
//! ```
//!
//! No independent contraction formulas are introduced: the wedge is the
//! antisymmetrized cup product from [`super::wedge`], and all geometry enters
//! through the existing diagonal Hodge star.
//!
//! ## Primal–dual transport
//!
//! The diagonal star produces *dual* cochains indexed by their primal cells.
//! Feeding a dual cochain back into the (primal) wedge requires transporting
//! it onto the primal cells of the complementary grade. For a source k-cell
//! `(p, A)` the dual cell is centered at `p + ½·Σ_{a∈A} e_a` spanning the
//! complementary axes `Aᶜ`; the transport therefore averages, for each target
//! `(D−k)`-cell `(q, Aᶜ)`, over the `2^D` source cells with offsets
//! `δ_a ∈ {−1, 0}` along the source axes `a ∈ A` and `δ_b ∈ {0, +1}` along the
//! target axes `b ∈ Aᶜ` (wrapped on periodic axes; dropped-and-renormalized on
//! open boundaries). Each transported value carries the orientation sign
//! `ε(A, Aᶜ)` of the permutation sorting `(A asc, Aᶜ asc)` into `(0, …, D−1)`
//! — this is what realizes `⋆dx² = −dx¹` in 2D and its higher-dimensional
//! analogues with an unsigned diagonal star. The centered averaging makes the
//! transport second-order accurate on uniform lattices.

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use crate::errors::topology_error::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use crate::types::manifold::Manifold;

#[cfg(feature = "parallel")]
use rayon::prelude::*;

use crate::types::manifold::differential::utils_differential;
use deep_causality_par::MaybeParallel;

impl<const D: usize, R> Manifold<LatticeComplex<D, R>, R>
where
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + core::fmt::Debug,
{
    /// Computes the discrete interior product `i_X ω` of a 1-form `x_flat`
    /// (the contraction direction `X♭`) with a k-form `omega`, producing a
    /// (k−1)-form, via `(−1)^{k(D−k)} ⋆(⋆ω ∧ X♭)`.
    ///
    /// # Errors
    /// * `TopologyError::InvalidGradeOperation` when `k == 0` (a 0-form has
    ///   nothing to contract) or `k > D`.
    /// * `TopologyError::DimensionMismatch` when `x_flat` is not a 1-form of
    ///   length `num_cells(1)` or `omega` is not of length `num_cells(k)`.
    /// * `TopologyError::InvalidInput` when the manifold has no metric (the
    ///   star is metric-dependent).
    pub fn interior_product(
        &self,
        x_flat: &CausalTensor<R>,
        omega: &CausalTensor<R>,
        k: usize,
    ) -> Result<CausalTensor<R>, TopologyError> {
        let complex = &self.complex;

        if k == 0 || k > D {
            return Err(TopologyError::InvalidGradeOperation(format!(
                "interior_product requires 1 <= k <= D; got k = {k} on a D = {D} lattice"
            )));
        }
        if x_flat.len() != complex.num_cells(1) {
            return Err(TopologyError::DimensionMismatch(format!(
                "interior_product contraction field: expected {} grade-1 coefficients, got {}",
                complex.num_cells(1),
                x_flat.len()
            )));
        }
        if omega.len() != complex.num_cells(k) {
            return Err(TopologyError::DimensionMismatch(format!(
                "interior_product form operand: expected {} grade-{} coefficients, got {}",
                complex.num_cells(k),
                k,
                omega.len()
            )));
        }
        let metric = self.metric.as_ref().ok_or_else(|| {
            TopologyError::InvalidInput(
                "interior_product requires a metric; construct the manifold with a metric attached"
                    .to_string(),
            )
        })?;

        // ⋆ω — a dual (D−k)-cochain, indexed by primal k-cells. The star
        // surface is validated when the metric is attached, so a failure here
        // is unreachable through the public construction path.
        let star_k = metric
            .hodge_star_matrix(complex, k)
            .map_err(|e| TopologyError::InvalidInput(format!("hodge star (grade {k}): {e}")))?;
        let star_omega =
            utils_differential::apply_metric_operator(star_k.as_ref(), omega.as_slice());

        // Transport onto primal (D−k)-cells (with orientation signs).
        let star_omega_primal = dual_to_primal_complement(complex, &star_omega, k);
        let n_dk = complex.num_cells(D - k);
        let star_omega_tensor = CausalTensor::new(star_omega_primal, vec![n_dk])
            .expect("transport output tensor allocation cannot fail for a 1-D shape");

        // ⋆ω ∧ X♭ — grade D−k+1. Grade overflow is impossible here (k >= 1),
        // and both operand lengths are correct by construction, so the inner
        // wedge cannot fail; propagate defensively all the same.
        let wedged = self.wedge(&star_omega_tensor, D - k, x_flat, 1)?;

        // ⋆(⋆ω ∧ X♭) — a dual (k−1)-cochain indexed by primal (D−k+1)-cells.
        let star_back = metric.hodge_star_matrix(complex, D - k + 1).map_err(|e| {
            TopologyError::InvalidInput(format!("hodge star (grade {}): {e}", D - k + 1))
        })?;

        let star_wedged =
            utils_differential::apply_metric_operator(star_back.as_ref(), wedged.as_slice());

        // Transport onto primal (k−1)-cells and apply the overall sign.
        let mut result = dual_to_primal_complement(complex, &star_wedged, D - k + 1);
        if (k * (D - k)) % 2 == 1 {
            for v in result.iter_mut() {
                *v = R::zero() - *v;
            }
        }

        let len = result.len();
        Ok(CausalTensor::new(result, vec![len])
            .expect("interior product output tensor allocation cannot fail for a 1-D shape"))
    }
}

/// Transport a dual cochain (indexed by primal `k_src`-cells) onto the primal
/// cells of the complementary grade `D − k_src`, with centered averaging and
/// the orientation sign `ε(A, Aᶜ)`. See the module-level doc.
fn dual_to_primal_complement<const D: usize, R>(
    complex: &LatticeComplex<D, R>,
    dual_vals: &[R],
    k_src: usize,
) -> Vec<R>
where
    R: RealField + FromPrimitive + MaybeParallel,
{
    let shape = *complex.shape();
    let periodic = *complex.periodic();
    let full_mask: u32 = if D == 32 { u32::MAX } else { (1u32 << D) - 1 };

    // The per-target transport: read-only over the source map and values,
    // so the targets are independent — the loop fans out over Rayon under
    // the `parallel` feature.
    let per_target = |target: LatticeCell<D>| {
        let b_mask = target.orientation();
        let a_mask = full_mask & !b_mask;

        // ε(A, Aᶜ): inversions between source axes A and target axes B.
        let mut inversions = 0usize;
        for a in 0..D {
            if a_mask & (1 << a) != 0 {
                for b in 0..a {
                    if b_mask & (1 << b) != 0 {
                        inversions += 1;
                    }
                }
            }
        }
        let negate = inversions % 2 == 1;

        let mut acc = R::zero();
        let mut count = 0usize;

        // 2^D offset combinations: bit d set means "shift along axis d"
        // (−1 for source axes, +1 for target axes).
        for combo in 0..(1u32 << D) {
            let mut pos = *target.position();
            let mut in_range = true;

            for (d, p) in pos.iter_mut().enumerate() {
                if combo & (1 << d) == 0 {
                    continue;
                }
                if a_mask & (1 << d) != 0 {
                    // Source axis: shift −1.
                    if *p == 0 {
                        if periodic[d] {
                            *p = shape[d] - 1;
                        } else {
                            in_range = false;
                            break;
                        }
                    } else {
                        *p -= 1;
                    }
                } else {
                    // Target axis: shift +1.
                    *p += 1;
                    if *p >= shape[d] {
                        if periodic[d] {
                            *p -= shape[d];
                        } else {
                            // Defensive: unreachable — a target cell's
                            // active axis position is at most shape−2 on
                            // an open lattice, so the +1 shift stays in
                            // range (documented coverage exemption per
                            // AGENTS.md; kept for symmetry with the −1
                            // branch).
                            in_range = false;
                            break;
                        }
                    }
                }
            }
            if !in_range {
                continue;
            }

            let src = LatticeCell::new(pos, a_mask);
            if let Some(i) = complex.cell_index(&src) {
                acc += dual_vals[i];
                count += 1;
            }
        }

        if count == 0 {
            // Defensive: unreachable for any lattice with extent >= 2 on
            // every axis — the all-shifted offset combination always lands
            // on an existing source cell (documented coverage exemption
            // per AGENTS.md; degenerate extent-1 lattices have no 1-cells
            // and therefore no interior-product inputs).
            return R::zero();
        }
        let count_r =
            <R as FromPrimitive>::from_usize(count).expect("cell count lifts into RealField");
        let avg = acc / count_r;
        if negate { R::zero() - avg } else { avg }
    };

    // Per-target work is a 2^D offset enumeration; the cutoff matches the
    // wedge's per-cell threshold.
    #[cfg(feature = "parallel")]
    if complex.num_cells(D - k_src) >= 1 << 12 {
        let targets: Vec<LatticeCell<D>> = complex.iter_cells(D - k_src).collect();
        return targets.into_par_iter().map(per_target).collect();
    }
    complex.iter_cells(D - k_src).map(per_target).collect()
}
