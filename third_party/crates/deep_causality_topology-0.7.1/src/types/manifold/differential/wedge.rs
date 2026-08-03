/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Discrete wedge product on cubical lattice cochains.
//!
//! The wedge is the antisymmetrized cubical cup product. For a (k+l)-cube `Q`
//! with base position `p` and active-axis set `A` (|A| = k + l), the cup
//! product of a k-form `α` and an l-form `β` is
//!
//! ```text
//! (α ∪ β)(Q) = Σ_{A = H ⊔ T, |H| = k} ρ(H, T) · α(front_H(Q)) · β(back_T(Q))
//! ```
//!
//! where `front_H(Q)` is the k-face spanned by `H` at the base corner,
//! `back_T(Q)` is the l-face spanned by `T` at the corner shifted by one along
//! every axis in `H` (wrapped on periodic axes), and `ρ(H, T)` is the shuffle
//! sign: `(−1)^{#{(h, t) ∈ H × T : h > t}}`.
//!
//! The cup product satisfies the Leibniz rule exactly at cochain level but is
//! graded-commutative only up to homotopy; the **wedge** restores exact graded
//! commutativity by antisymmetrization:
//!
//! ```text
//! α ∧ β = ½ (α ∪ β + (−1)^{kl} β ∪ α)
//! ```
//!
//! Both Leibniz (`d(α∧β) = dα∧β + (−1)^k α∧dβ`) and graded commutativity
//! (`α∧β = (−1)^{kl} β∧α`) then hold exactly; the latter by construction, the
//! former because antisymmetrization is a linear combination of two products
//! that each satisfy it. The wedge is purely combinatorial: no metric is
//! required (all geometry enters through the Hodge star elsewhere).
//!
//! Reference: Hirani, *Discrete Exterior Calculus*, Caltech 2003 (primal–primal
//! wedge); the cubical cup product is the axis-aligned specialization.

#[cfg(feature = "parallel")]
use rayon::prelude::*;

use deep_causality_par::MaybeParallel;

use deep_causality_algebra::RealField;
use deep_causality_tensor::CausalTensor;

use crate::errors::topology_error::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use crate::types::manifold::Manifold;

impl<const D: usize, R> Manifold<LatticeComplex<D, R>, R>
where
    R: RealField + MaybeParallel + Default + PartialEq + core::fmt::Debug,
{
    /// Computes the discrete wedge product `α ∧ β` of a k-form and an l-form,
    /// producing a (k+l)-form on this manifold's lattice complex.
    ///
    /// The wedge is the antisymmetrized cubical cup product (module-level doc):
    /// bilinear, exactly graded-anticommutative (`α∧β = (−1)^{kl} β∧α`), and
    /// satisfying the Leibniz rule exactly at cochain level. It is
    /// metric-free; the manifold's metric is not consulted.
    ///
    /// # Arguments
    /// * `alpha` — k-form coefficients, length `num_cells(k)`.
    /// * `k` — grade of `alpha`.
    /// * `beta` — l-form coefficients, length `num_cells(l)`.
    /// * `l` — grade of `beta`.
    ///
    /// # Errors
    /// * `TopologyError::InvalidGradeOperation` when `k + l > D`.
    /// * `TopologyError::DimensionMismatch` when either operand's length does
    ///   not match the cell count of its grade.
    pub fn wedge(
        &self,
        alpha: &CausalTensor<R>,
        k: usize,
        beta: &CausalTensor<R>,
        l: usize,
    ) -> Result<CausalTensor<R>, TopologyError> {
        let complex = &self.complex;

        if k + l > D {
            return Err(TopologyError::InvalidGradeOperation(format!(
                "wedge grade overflow: k + l = {} exceeds lattice dimension D = {}",
                k + l,
                D
            )));
        }
        if alpha.len() != complex.num_cells(k) {
            return Err(TopologyError::DimensionMismatch(format!(
                "wedge first operand: expected {} grade-{} coefficients, got {}",
                complex.num_cells(k),
                k,
                alpha.len()
            )));
        }
        if beta.len() != complex.num_cells(l) {
            return Err(TopologyError::DimensionMismatch(format!(
                "wedge second operand: expected {} grade-{} coefficients, got {}",
                complex.num_cells(l),
                l,
                beta.len()
            )));
        }

        let ab = cup(complex, alpha.as_slice(), k, beta.as_slice(), l);
        let ba = cup(complex, beta.as_slice(), l, alpha.as_slice(), k);

        // α ∧ β = ½ (α ∪ β + (−1)^{kl} β ∪ α)
        let two = R::one() + R::one();
        let kl_sign_negative = (k * l) % 2 == 1;
        let out: Vec<R> = ab
            .into_iter()
            .zip(ba)
            .map(|(x, y)| {
                let combined = if kl_sign_negative { x - y } else { x + y };
                combined / two
            })
            .collect();

        let len = out.len();
        Ok(CausalTensor::new(out, vec![len])
            .expect("wedge output tensor allocation cannot fail for a 1-D shape"))
    }
}

/// The raw cubical cup product `(α ∪ β)` of a k-form and an l-form, as a
/// (k+l)-cochain in canonical ordering. See the module-level doc for the
/// formula and conventions.
fn cup<const D: usize, R>(
    complex: &LatticeComplex<D, R>,
    alpha: &[R],
    k: usize,
    beta: &[R],
    _l: usize,
) -> Vec<R>
where
    R: RealField + MaybeParallel,
{
    let kl = k + _l;
    let shape = *complex.shape();
    let periodic = *complex.periodic();

    // The per-cell cup evaluation: read-only over the operand slices and
    // index maps, so the output cells are independent — the loop fans out
    // over Rayon under the `parallel` feature.
    let per_cell = |q: LatticeCell<D>| {
        // Active axes of Q in ascending order.
        let axes: Vec<usize> = (0..D).filter(|i| q.orientation() & (1 << i) != 0).collect();

        let mut acc = R::zero();

        // Every |H| = k subset of the k+l active axes.
        for subset in 0..(1u32 << kl) {
            if subset.count_ones() as usize != k {
                continue;
            }

            // Shuffle sign ρ(H, T): inversions between H and T bit
            // positions. Axes are ascending, so axis order == bit order.
            let mut inversions = 0usize;
            for i in 0..kl {
                if subset & (1 << i) != 0 {
                    for j in 0..i {
                        if subset & (1 << j) == 0 {
                            inversions += 1;
                        }
                    }
                }
            }

            let mut h_mask = 0u32;
            for (i, &axis) in axes.iter().enumerate() {
                if subset & (1 << i) != 0 {
                    h_mask |= 1 << axis;
                }
            }
            let t_mask = q.orientation() & !h_mask;

            // Front face: spanned by H at the base corner.
            let front = LatticeCell::new(*q.position(), h_mask);

            // Back face: spanned by T at the corner shifted by one along
            // every H axis, wrapped on periodic axes. On open lattices the
            // shifted position is always in range because Q itself exists.
            let mut back_pos = *q.position();
            for (i, &axis) in axes.iter().enumerate() {
                if subset & (1 << i) != 0 {
                    back_pos[axis] += 1;
                    if periodic[axis] && back_pos[axis] >= shape[axis] {
                        back_pos[axis] -= shape[axis];
                    }
                }
            }
            let back = LatticeCell::new(back_pos, t_mask);

            let a = alpha[complex
                .cell_index(&front)
                .expect("front face of an existing cell is always a valid lattice cell")];

            let b = beta[complex
                .cell_index(&back)
                .expect("back face of an existing cell is always a valid lattice cell")];

            let term = a * b;
            acc = if inversions % 2 == 1 {
                acc - term
            } else {
                acc + term
            };
        }

        acc
    };

    // Per-cell work is a subset enumeration (2^(k+l) terms), so the
    // profitable cutoff sits well below the matvec one.
    #[cfg(feature = "parallel")]
    if complex.num_cells(kl) >= 1 << 12 {
        let cells: Vec<LatticeCell<D>> = complex.iter_cells(kl).collect();
        return cells.into_par_iter().map(per_cell).collect();
    }
    complex.iter_cells(kl).map(per_cell).collect()
}
