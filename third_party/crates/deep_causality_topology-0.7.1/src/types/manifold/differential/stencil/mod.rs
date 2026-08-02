/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Compiled stencil tables for the cubical-lattice DEC operator pipeline.
//!
//! On a lattice every operator the NS rate evaluates has a fixed gather
//! pattern known at manifold construction: the exterior derivative and
//! codifferential are ±1 incidences scaled by diagonal Hodge factors, and
//! the interior product is a sparse transport — diagonal star — wedge —
//! diagonal star — sparse transport chain around one bilinear cup stage.
//! [`DecStencilTables::compile`] walks those enumerations once, folding
//! every constant (signs, star diagonals, averaging weights, the ½
//! antisymmetrization) into flat coefficient tables; the apply methods are
//! then pure gather–multiply–accumulate streams with no CSR column
//! lookups, no per-cell index arithmetic, and no heap allocation.
//!
//! The tables are an evaluation strategy, not new mathematics: the generic
//! compositional operators remain intact and are the equivalence oracle
//! (`tests/types/manifold/stencil_tests.rs`). Ownership is explicit — the
//! solver holds the tables; nothing is cached inside `Manifold` (the same
//! conclusion as the FFT plan-cache decision in `add-fft` design D8).

mod bilinear_op;
pub(in crate::types::manifold::differential) mod build;
mod stencil_op;

use core::fmt::Debug;

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_par::MaybeParallel;

use crate::errors::topology_error::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::lattice_complex::LatticeComplex;
use crate::types::manifold::Manifold;
use crate::types::manifold::differential::stencil::bilinear_op::BilinearOp;
use crate::types::manifold::differential::stencil::build::{
    build_d, build_delta, build_transport, build_wedge_a_1, star_diag,
};
use crate::types::manifold::differential::stencil::stencil_op::StencilOp;

/// Compiled stencil tables for the grade-1 NS rate pipeline on one
/// cubical-lattice manifold: `d₀`, `d₁`, `δ₁`, `δ₂` (Hodge factors
/// folded), and the convective chain `i_X ω = (−1)^{k(D−k)}
/// ⋆(⋆ω ∧ X♭)` for a 2-form `ω`, compiled as
/// `post · W(pre · ω, X♭)`.
///
/// Build once per manifold with [`DecStencilTables::compile`]; apply any
/// number of times with caller buffers. See the module doc.
#[derive(Debug, Clone)]
pub struct DecStencilTables<R> {
    /// Cell counts per grade `0..=D` (validation surface).
    num_cells: Vec<usize>,
    d0: StencilOp<R>,
    d1: StencilOp<R>,
    delta1: StencilOp<R>,
    delta2: StencilOp<R>,
    conv_pre: StencilOp<R>,
    conv_wedge: BilinearOp<R>,
    conv_post: StencilOp<R>,
    /// Static transposes for the M-adjoint of the **vector-slot** map
    /// `G_ω : x ↦ i_x ω` at fixed 2-form `ω` —
    /// `G*_ω = M₁⁻¹ Wᵇᵀ Postᵀ M₁` — the skew-symmetrization of the
    /// dec-ns-stability fix (the continuum antisymmetry lives in the
    /// vector slot: `ω(x, w) = −ω(w, x)` pointwise, so this slot's skew
    /// part is full-strength and exactly energy-neutral). Compiled once;
    /// applied as plain gathers.
    conv_wedge_bt: BilinearOp<R>,
    conv_post_t: StencilOp<R>,
    /// Grade-1 star diagonal and its guarded inverse (the M₁ weights of
    /// the vector-slot adjoint; a sub-tolerance mass inverts to zero,
    /// mirroring the generic codifferential's guard).
    star1: Vec<R>,
    inv_star1: Vec<R>,
}

impl<R> DecStencilTables<R>
where
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + Debug,
{
    /// Compile the tables from a metric-bearing cubical manifold.
    ///
    /// # Errors
    /// * `TopologyError::InvalidGradeOperation` when `D < 2` (the NS rate
    ///   pipeline needs 2-forms).
    /// * `TopologyError::InvalidInput` when the manifold has no metric or
    ///   a Hodge star matrix is unavailable.
    pub fn compile<const D: usize>(
        manifold: &Manifold<LatticeComplex<D, R>, R>,
    ) -> Result<Self, TopologyError> {
        if D < 2 {
            return Err(TopologyError::InvalidGradeOperation(format!(
                "DecStencilTables requires a lattice of dimension >= 2; got D = {D}"
            )));
        }
        let complex = manifold.complex();
        let metric = manifold.metric.as_ref().ok_or_else(|| {
            TopologyError::InvalidInput(
                "DecStencilTables requires a metric; construct the manifold with a metric attached"
                    .to_string(),
            )
        })?;

        let num_cells: Vec<usize> = (0..=D).map(|k| complex.num_cells(k)).collect();

        // Diagonal star entries per grade the pipeline touches.
        let star_at = |k: usize| -> Result<Vec<R>, TopologyError> {
            let m = metric
                .hodge_star_matrix(complex, k)
                .map_err(|e| TopologyError::InvalidInput(format!("hodge star (grade {k}): {e}")))?;
            Ok(star_diag(m.as_ref(), complex.num_cells(k)))
        };
        let s0 = star_at(0)?;
        let s1 = star_at(1)?;
        let s2 = star_at(2)?;
        let s_dm1 = star_at(D - 1)?;

        let d0 = build_d(complex, 0);
        let d1 = build_d(complex, 1);
        let delta1 = build_delta(complex, &s1, &s0, 1);
        let delta2 = build_delta(complex, &s2, &s1, 2);

        // Convective chain for k = 2: pre = transport(2) ∘ diag(⋆₂);
        // wedge of (D−2)-form with the 1-form; post = transport(D−1) ∘
        // diag(⋆_{D−1}) with the global (−1)^{k(D−k)} (even for k = 2,
        // kept general).
        let global_negative = (2 * (D - 2)) % 2 == 1;
        let conv_pre = build_transport(complex, 2, &s2, false);
        let conv_wedge = build_wedge_a_1(complex, D - 2);
        let conv_post = build_transport(complex, D - 1, &s_dm1, global_negative);

        // Static transposes for the vector-slot convective M-adjoint
        // (the dec-ns-stability skew fix).
        let conv_wedge_bt = conv_wedge.transpose_b();
        let conv_post_t = conv_post.transpose();
        let zero_tol = <R as FromPrimitive>::from_f64(1e-12)
            .expect("1e-12 is representable in every RealField");
        let inv_star1: Vec<R> = s1
            .iter()
            .map(|&m| {
                if m.abs() <= zero_tol {
                    R::zero()
                } else {
                    R::one() / m
                }
            })
            .collect();

        Ok(Self {
            num_cells,
            d0,
            d1,
            delta1,
            delta2,
            conv_pre,
            conv_wedge,
            conv_post,
            conv_wedge_bt,
            conv_post_t,
            star1: s1,
            inv_star1,
        })
    }

    /// Cell count at grade `k` (panics on out-of-range grade).
    pub fn num_cells(&self, k: usize) -> usize {
        self.num_cells[k]
    }

    /// Scratch lengths for [`Self::apply_convective`]:
    /// `(pre output, wedge output)`.
    pub fn convective_scratch_lens(&self) -> (usize, usize) {
        (self.conv_pre.rows(), self.conv_wedge.rows())
    }

    /// `out = d₀ φ` (grade 0 → 1).
    pub fn apply_d0(&self, input: &[R], out: &mut [R]) -> Result<(), TopologyError> {
        check_len(input.len(), self.d0.cols(), "d0 input")?;
        check_len(out.len(), self.d0.rows(), "d0 output")?;
        self.d0.apply(input, out);
        Ok(())
    }

    /// `out = d₁ u♭` (grade 1 → 2).
    pub fn apply_d1(&self, input: &[R], out: &mut [R]) -> Result<(), TopologyError> {
        check_len(input.len(), self.d1.cols(), "d1 input")?;
        check_len(out.len(), self.d1.rows(), "d1 output")?;
        self.d1.apply(input, out);
        Ok(())
    }

    /// `out = δ₁ u♭` (grade 1 → 0, Hodge factors folded).
    pub fn apply_delta1(&self, input: &[R], out: &mut [R]) -> Result<(), TopologyError> {
        check_len(input.len(), self.delta1.cols(), "delta1 input")?;
        check_len(out.len(), self.delta1.rows(), "delta1 output")?;
        self.delta1.apply(input, out);
        Ok(())
    }

    /// `out = δ₂ ω` (grade 2 → 1, Hodge factors folded).
    pub fn apply_delta2(&self, input: &[R], out: &mut [R]) -> Result<(), TopologyError> {
        check_len(input.len(), self.delta2.cols(), "delta2 input")?;
        check_len(out.len(), self.delta2.rows(), "delta2 output")?;
        self.delta2.apply(input, out);
        Ok(())
    }

    /// `out = i_X ω` for a 2-form `ω` and 1-form `x_flat`, through the
    /// compiled chain. `pre_buf`/`wedge_buf` must have the lengths
    /// reported by [`Self::convective_scratch_lens`].
    pub fn apply_convective(
        &self,
        omega: &[R],
        x_flat: &[R],
        pre_buf: &mut [R],
        wedge_buf: &mut [R],
        out: &mut [R],
    ) -> Result<(), TopologyError> {
        check_len(omega.len(), self.conv_pre.cols(), "convective omega")?;
        check_len(x_flat.len(), self.conv_wedge.cols_b(), "convective x_flat")?;
        check_len(
            pre_buf.len(),
            self.conv_pre.rows(),
            "convective pre scratch",
        )?;
        check_len(
            wedge_buf.len(),
            self.conv_wedge.rows(),
            "convective wedge scratch",
        )?;
        check_len(out.len(), self.conv_post.rows(), "convective output")?;
        debug_assert_eq!(self.conv_wedge.cols_a(), self.conv_pre.rows());
        debug_assert_eq!(self.conv_post.cols(), self.conv_wedge.rows());

        self.conv_pre.apply(omega, pre_buf);
        self.conv_wedge.apply(pre_buf, x_flat, wedge_buf);
        self.conv_post.apply(wedge_buf, out);
        Ok(())
    }

    /// Scratch lengths for [`Self::apply_convective_vector_adjoint`]:
    /// `(grade-1, wedge-rows)`.
    pub fn convective_vector_adjoint_scratch_lens(&self) -> (usize, usize) {
        (self.conv_post.rows(), self.conv_wedge.rows())
    }

    /// `out = G*_ω w = M₁⁻¹ Wᵇᵀ(p, Postᵀ(M₁ w))` — the M-adjoint of the
    /// **vector-slot** convective map `G_ω : x ↦ i_x ω` at fixed 2-form
    /// `ω`, where `p = Pre·ω` is the forward chain's transport stage
    /// (pass the `pre_buf` filled by [`Self::apply_convective`]). This is
    /// the adjoint half of the skew-symmetrized convective term
    /// `conv'(u) = ½[G_ω u − G*_ω u]` with `ω = du`: exactly
    /// energy-neutral (`⟨u, conv'⟩_M = 0` identically) and full-strength
    /// consistent (the continuum antisymmetry `ω(x, w) = −ω(w, x)` lives
    /// in this slot) — the dec-ns-stability fix.
    ///
    /// `scratch_n1`/`scratch_wedge` must have the lengths reported by
    /// [`Self::convective_vector_adjoint_scratch_lens`].
    pub fn apply_convective_vector_adjoint(
        &self,
        pre_buf: &[R],
        w: &[R],
        scratch_n1: &mut [R],
        scratch_wedge: &mut [R],
        out: &mut [R],
    ) -> Result<(), TopologyError> {
        check_len(pre_buf.len(), self.conv_pre.rows(), "vector-adjoint pre")?;
        check_len(w.len(), self.conv_post.rows(), "vector-adjoint w")?;
        check_len(
            scratch_n1.len(),
            self.conv_post.rows(),
            "vector-adjoint n1 scratch",
        )?;
        check_len(
            scratch_wedge.len(),
            self.conv_wedge.rows(),
            "vector-adjoint wedge scratch",
        )?;
        check_len(out.len(), self.conv_post.rows(), "vector-adjoint output")?;

        // M₁ ⊙ w, the transposed post stage, the b-transposed wedge at
        // fixed transport image `p`, then M₁⁻¹.
        for ((s, a), m) in scratch_n1.iter_mut().zip(w.iter()).zip(self.star1.iter()) {
            *s = *a * *m;
        }
        self.conv_post_t.apply(scratch_n1, scratch_wedge);
        self.conv_wedge_bt.apply(pre_buf, scratch_wedge, out);
        for (o, inv) in out.iter_mut().zip(self.inv_star1.iter()) {
            *o *= *inv;
        }
        Ok(())
    }
}

fn check_len(got: usize, expected: usize, what: &str) -> Result<(), TopologyError> {
    if got != expected {
        return Err(TopologyError::DimensionMismatch(format!(
            "DecStencilTables {what}: expected {expected}, got {got}"
        )));
    }
    Ok(())
}
