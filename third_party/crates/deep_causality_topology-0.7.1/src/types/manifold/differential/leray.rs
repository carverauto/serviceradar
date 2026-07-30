/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The Leray projection: the divergence-free component of a 1-form via the
//! *half* Hodge decomposition.
//!
//! `P(ω) = ω − dφ` with `Δ₀ φ = δω`, gauge-fixed by mean subtraction — the
//! grade-0 Poisson solve only. The β-step of the full decomposition never
//! runs: the projector costs **one** CG solve per evaluation, and the
//! harmonic-kernel question of `Δ_{k+1}` on periodic lattices does not arise
//! on this path (see `cfd-gap.md` §2 of the `add-dec-solver-foundations`
//! change). On a torus the harmonic component (the mean flow) is
//! divergence-free and is retained unchanged by `ω − dφ`.
//!
//! The grade-0 potential is returned alongside the projected field
//! ([`crate::LerayProjection`]); the opt-in pressure-recovery diagnostic
//! consumes it downstream.

use core::fmt::{Debug, Display};

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use crate::errors::topology_error::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::cut_cell::CutFaceConstraint;
use crate::types::hodge_decomposition::HodgeDecomposition;
use crate::types::leray_projection::LerayProjection;
use crate::types::manifold::Manifold;
use crate::types::manifold::differential::HodgeDecomposeOptions;
use crate::types::manifold::differential::hodge_decomposition_impl::{
    pad_or_truncate, resolve_cg_tolerance, solve_laplacian,
};
use crate::utils::cg_solver::subtract_mean_in_place;
use deep_causality_par::MaybeParallel;

impl<K, R> Manifold<K, R>
where
    K: ChainComplex + Clone,
    K::Metric: HasHodgeStar<R, Complex = K> + Clone,
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + Debug + Display,
{
    /// Leray projection of a 1-form with default tolerance and iteration
    /// budget: removes the gradient component, returning the divergence-free
    /// field and the grade-0 potential. See the module doc.
    ///
    /// # Errors
    /// * `TopologyError::DimensionMismatch` when `field` is not of length
    ///   `num_cells(1)`.
    /// * `TopologyError::InvalidInput` when the manifold has no metric.
    /// * `TopologyError::HodgeDecompositionFailed` when the grade-0 CG solve
    ///   does not converge within the iteration budget (or the caller
    ///   supplies a non-positive tolerance via the `_opts` variant).
    pub fn leray_project(
        &self,
        field: &CausalTensor<R>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        self.leray_project_opts(field, &HodgeDecomposeOptions::default())
    }

    /// Leray projection with caller-supplied tolerance / iteration budget.
    /// See [`Self::leray_project`].
    pub fn leray_project_opts(
        &self,
        field: &CausalTensor<R>,
        opts: &HodgeDecomposeOptions<R>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        let n1 = self.complex.num_cells(1);
        if field.len() != n1 {
            return Err(TopologyError::DimensionMismatch(format!(
                "leray_project: expected {} grade-1 coefficients, got {}",
                n1,
                field.len()
            )));
        }
        if self.metric.is_none() {
            return Err(TopologyError::InvalidInput(
                "leray_project requires a metric; construct the manifold with a metric attached"
                    .to_string(),
            ));
        }

        let tolerance = resolve_cg_tolerance(opts.tolerance)?;
        let max_iter = opts.max_iterations.unwrap_or(1000);
        let n0 = self.complex.num_cells(0);

        // δω — the divergence source for the grade-0 Poisson solve,
        // evaluated directly on the field (no temporary manifold).
        let delta_omega = self.codifferential_of(field.as_slice(), 1);
        let mut rhs = delta_omega.into_vec();
        pad_or_truncate(&mut rhs, n0);
        // Grade-0 gauge: constants are always harmonic (β₀ = 1). The RHS
        // kernel projection happens inside `solve_laplacian` on the
        // mass-weighted system (Euclidean subtraction here would break
        // M-consistency on boundary-clipped lattices); the solution's
        // gauge is fixed below.

        let mut phi = solve_laplacian(self, 0, &rhs, tolerance, max_iter)?;
        subtract_mean_in_place(&mut phi);

        // P(ω) = ω − dφ, with dφ evaluated directly on the potential.
        let d_phi = self.exterior_derivative_of(&phi, 0);
        let mut grad = d_phi.into_vec();
        pad_or_truncate(&mut grad, n1);

        let projected: Vec<R> = field
            .as_slice()
            .iter()
            .zip(grad.iter())
            .map(|(w, g)| *w - *g)
            .collect();

        let projected_t =
            CausalTensor::new(projected, vec![n1]).expect("1-D tensor allocation cannot fail");
        let potential_t =
            CausalTensor::new(phi, vec![n0]).expect("1-D tensor allocation cannot fail");

        Ok(LerayProjection::new(projected_t, potential_t))
    }

    /// The **constrained** Leray projection: the M-orthogonal projection
    /// onto the intersection of the divergence-free subspace with the
    /// essential-constraint subspace `S = {u : u|_E = 0}` for a caller-given
    /// edge set `E` (the no-slip wall-tangential edges of the
    /// no-slip-viscous capability).
    ///
    /// The plain projector and the coordinate projector onto `S` do not
    /// commute, so composing them post hoc cannot produce a field that is
    /// simultaneously divergence-free and constrained. The intersection
    /// projection follows from the KKT conditions: with `v = P_S(field)`,
    ///
    /// ```text
    /// u = v − P_F dφ,   (∂ M₁|_F d) φ = ∂ M₁ v
    /// ```
    ///
    /// where `M₁|_F` zeroes the constrained edges' masses and `P_F` masks
    /// the gradient correction to the free edges. Then `δu = 0` **and**
    /// `u|_E = 0`, both exactly: the constrained edges carry zero values, so
    /// the full (unmasked) divergence agrees with the masked one. The
    /// masked operator loses the per-axis separability of the spectral
    /// paths (wall rows drop their tangential coupling), so the solve runs
    /// Jacobi-preconditioned CG; the direct DCT/DFT solve remains the
    /// unconstrained dispatch (and the natural future preconditioner).
    ///
    /// Vertices whose every incident edge is constrained (all-walls box
    /// corners and, in 3D, lattice-edge vertices) yield structurally null
    /// rows: their rhs entries are zeroed and the gauge projection runs
    /// over the connected block, so CG never excites those coordinates.
    ///
    /// An empty `constrained_edges` delegates to
    /// [`Self::leray_project_opts`] (bit-identical periodic path).
    ///
    /// # Errors
    /// * `TopologyError::DimensionMismatch` on a field-length mismatch.
    /// * `TopologyError::InvalidInput` when the manifold has no metric or
    ///   an edge index is out of range.
    /// * `TopologyError::HodgeDecompositionFailed` when the CG solve does
    ///   not converge (or a non-positive tolerance is supplied).
    pub fn leray_project_constrained_opts(
        &self,
        field: &CausalTensor<R>,
        constrained_edges: &[usize],
        opts: &HodgeDecomposeOptions<R>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        // The constrained projection is the closed-domain special case of the open-boundary
        // projection: constrained edges fixed to zero, no prescribed (inflow) edges, no outflow
        // reference. Because the fixed edges carry value zero, the full-mass divergence RHS agrees
        // with the masked-mass one, so this is bit-identical to the former standalone path.
        self.leray_project_open_opts(field, constrained_edges, &[], &[], opts)
    }

    /// The **open-boundary** Leray projection: the constrained projection generalized to admit a
    /// prescribed inflow (nonzero net boundary flux) under mixed boundary conditions.
    ///
    /// Three roles partition the edges/vertices:
    /// * `zeroed_edges` — fixed to zero (no-slip / wall-tangential); excluded from the free solve.
    /// * `prescribed_edges` — fixed to their current `field` value (a Dirichlet inflow); excluded
    ///   from the free solve, but their flux **is counted** in the divergence right-hand side.
    /// * `reference_vertices` — the outflow pressure reference (`φ = 0`): it fixes the Poisson
    ///   nullspace and lets the complementary (free) outflow flux adjust so the net flux leaves
    ///   there and mass is conserved (`∮ u·n = 0` over the divergence-free interior).
    ///
    /// Masking an inflow edge disconnects its outer (ghostless) inlet vertex from the interior in
    /// the free-edge graph; the divergence is therefore enforced only on the component reachable
    /// from the reference (a flood fill over the free edges). The disconnected inlet ring carries
    /// the prescribed velocity but its divergence is not constrained — exactly the open-boundary
    /// condition. A prescribed inflow with **no** reference is rejected (the net flux has nowhere
    /// to leave under the all-Neumann gauge).
    ///
    /// With all three empty this is the plain projection; with only `zeroed_edges` it is the
    /// constrained projection, bit-identically.
    ///
    /// # Errors
    /// * `TopologyError::DimensionMismatch` on a field-length mismatch.
    /// * `TopologyError::InvalidInput` for a missing metric, an out-of-range edge/vertex, a
    ///   fully-constrained domain, or prescribed (inflow) edges without a reference.
    /// * `TopologyError::HodgeDecompositionFailed` when the CG solve does not converge.
    pub fn leray_project_open_opts(
        &self,
        field: &CausalTensor<R>,
        zeroed_edges: &[usize],
        prescribed_edges: &[usize],
        reference_vertices: &[usize],
        opts: &HodgeDecomposeOptions<R>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        self.leray_project_open_guess(
            field,
            zeroed_edges,
            prescribed_edges,
            reference_vertices,
            opts,
            None,
        )
    }

    /// As [`Self::leray_project_open_opts`], with a **warm-start** initial guess `x0` for the
    /// projection CG (the previous solve's grade-0 potential). The guess only accelerates
    /// convergence; the returned projection is the same to tolerance regardless of `x0`. With an
    /// all-empty edge/vertex partition the call delegates to the plain projection and `x0` is
    /// ignored (that path's CG is not warm-startable here).
    ///
    /// # Errors
    /// As [`Self::leray_project_open_opts`].
    pub fn leray_project_open_warm_opts(
        &self,
        field: &CausalTensor<R>,
        zeroed_edges: &[usize],
        prescribed_edges: &[usize],
        reference_vertices: &[usize],
        opts: &HodgeDecomposeOptions<R>,
        x0: Option<&[R]>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        self.leray_project_open_guess(
            field,
            zeroed_edges,
            prescribed_edges,
            reference_vertices,
            opts,
            x0,
        )
    }

    /// As [`Self::leray_project_constrained_opts`], with a warm-start initial guess `x0`. See
    /// [`Self::leray_project_open_warm_opts`].
    ///
    /// # Errors
    /// As [`Self::leray_project_constrained_opts`].
    pub fn leray_project_constrained_warm_opts(
        &self,
        field: &CausalTensor<R>,
        constrained_edges: &[usize],
        opts: &HodgeDecomposeOptions<R>,
        x0: Option<&[R]>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        self.leray_project_open_guess(field, constrained_edges, &[], &[], opts, x0)
    }

    /// The **generalized constrained** Leray projection: the M-orthogonal projection onto the
    /// intersection of the divergence-free subspace with the affine constraint set `{Cᵀu = b}` of
    /// arbitrary *aperture-weighted* rows (the aperture-resolved immersed no-slip), on top of the
    /// binary `zeroed_edges` pins.
    ///
    /// The binary path masks single-edge `u_e = 0` pins out of the free solve; a fragment wall
    /// condition is instead a multi-edge linear row `Σ wₑ uₑ = b` (the aperture-weighted fragment
    /// velocity, contracted with the wall frame — [`crate::CutCellRegistry::cut_face_constraints`]),
    /// which cannot be eliminated edge-wise. Such rows are carried by Lagrange multipliers `λ` in
    /// the **same** KKT projection. Stacking the weighted divergence rows `∂₁M₁` and the wall rows
    /// `Cᵀ` into `G`, eliminating `u = f − M⁻¹Gᵀy`, gives the symmetric **positive-(semi)definite**
    /// dual system `G M⁻¹ Gᵀ y = G f − c` with `y = [φ; λ]`, solved by the same Jacobi-preconditioned
    /// CG as the binary path (a larger `n₀ + rows` system). The reconstructed
    /// `u = v − dφ − M⁻¹Cλ` (gradient correction masked to free edges) then satisfies `δu = 0`
    /// **and** `Cᵀu = b`, both to the solve tolerance.
    ///
    /// With **no** `constraint_rows` this delegates to [`Self::leray_project_constrained_warm_opts`]
    /// — bit-identical to the binary staircase path (the binary-equivalence guarantee). The
    /// warm-start guess `x0` is the previous solve's grade-0 potential (length `num_cells(0)`); the
    /// `λ` block is seeded at zero. Each row is internally rescaled to unit coefficient norm for
    /// conditioning, which leaves the solution `u` unchanged.
    ///
    /// This is the **constrained** gauge (no inflow/outflow reference); it is the per-stage
    /// projection path an immersed-body march runs every RK stage. For the open-boundary
    /// (inflow/outflow) state and seed projections, see [`Self::leray_project_open_weighted_opts`].
    ///
    /// # Errors
    /// * `TopologyError::DimensionMismatch` on a field-length mismatch.
    /// * `TopologyError::InvalidInput` for a missing metric, an out-of-range edge index, or a
    ///   fully-constrained domain.
    /// * `TopologyError::HodgeDecompositionFailed` when the CG solve does not converge.
    pub fn leray_project_constrained_weighted_opts(
        &self,
        field: &CausalTensor<R>,
        zeroed_edges: &[usize],
        constraint_rows: &[CutFaceConstraint<R>],
        opts: &HodgeDecomposeOptions<R>,
        x0: Option<&[R]>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        Ok(self
            .leray_project_open_weighted_guess(
                field,
                zeroed_edges,
                &[],
                &[],
                constraint_rows,
                opts,
                x0,
                None,
            )?
            .0)
    }

    /// As [`Self::leray_project_constrained_weighted_opts`], additionally returning the converged
    /// Lagrange multipliers (`λ`, one per emitted weighted row) and accepting a previous-step `λ`
    /// guess. Warm-starting **both** the φ block (`x0`) and the `λ` block (`lambda0`) is the per-stage
    /// hot path of an immersed-body march: in a developed (limit-cycle) flow both vary slowly, so the
    /// coupled CG converges in far fewer iterations than seeding `λ` at zero. The returned `λ` is the
    /// internal normalized-row multiplier vector; pass it straight back as `lambda0` next step (its
    /// length and ordering are stable for a static body). It is ignored if its length does not match
    /// the current emitted-row count (e.g. the body changed), falling back to a zero `λ` seed.
    ///
    /// # Errors
    /// As [`Self::leray_project_constrained_weighted_opts`].
    pub fn leray_project_constrained_weighted_warm(
        &self,
        field: &CausalTensor<R>,
        zeroed_edges: &[usize],
        constraint_rows: &[CutFaceConstraint<R>],
        opts: &HodgeDecomposeOptions<R>,
        x0: Option<&[R]>,
        lambda0: Option<&[R]>,
    ) -> Result<(LerayProjection<R>, Vec<R>), TopologyError> {
        self.leray_project_open_weighted_guess(
            field,
            zeroed_edges,
            &[],
            &[],
            constraint_rows,
            opts,
            x0,
            lambda0,
        )
    }

    /// The **open-boundary generalized** Leray projection: [`Self::leray_project_open_opts`] extended
    /// with aperture-weighted wall rows `{Cᵀu = b}`. This is the path the immersed-body state and
    /// seed projections run — the no-slip body must be enforced on the *state* every step, not only
    /// on the per-stage rate, because the Leray gradient correction `dφ` of a plain re-projection
    /// reintroduces wall slip (`Cᵀ dφ ≠ 0`); only the coupled KKT solve keeps `δu = 0` **and**
    /// `Cᵀu = b` simultaneously.
    ///
    /// The three binary roles (`zeroed_edges` / `prescribed_edges` inflow / `reference_vertices`
    /// outflow) behave exactly as in [`Self::leray_project_open_opts`]; the weighted rows append a
    /// Lagrange-multiplier block to the same SPD dual system. With no `constraint_rows` this delegates
    /// to the binary open path, bit-identically. `x0` warm-starts the φ block (the previous
    /// potential); the `λ` block is seeded at zero.
    ///
    /// # Errors
    /// As [`Self::leray_project_open_opts`], plus an out-of-range weighted-row edge index.
    #[allow(clippy::too_many_arguments)]
    pub fn leray_project_open_weighted_opts(
        &self,
        field: &CausalTensor<R>,
        zeroed_edges: &[usize],
        prescribed_edges: &[usize],
        reference_vertices: &[usize],
        constraint_rows: &[CutFaceConstraint<R>],
        opts: &HodgeDecomposeOptions<R>,
        x0: Option<&[R]>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        Ok(self
            .leray_project_open_weighted_guess(
                field,
                zeroed_edges,
                prescribed_edges,
                reference_vertices,
                constraint_rows,
                opts,
                x0,
                None,
            )?
            .0)
    }

    /// The unified augmented-KKT solve behind the weighted constrained/open projections. Merges the
    /// open-gauge φ machinery (free-mass masking, reference flood-fill, symmetric elimination) of
    /// [`Self::leray_project_open_guess`] with a Lagrange-multiplier block for the weighted rows,
    /// solving the SPD dual system `G M⁻¹ Gᵀ y = G f − c`, `y = [φ; λ]`, `G = [∂₁M₁ ; Cᵀ]`.
    /// Returns the projection and the converged normalized-row multipliers `λ` (empty when the call
    /// degenerates to the binary path); `lambda0` warm-starts the `λ` block when its length matches
    /// the emitted-row count.
    #[allow(clippy::too_many_arguments)]
    fn leray_project_open_weighted_guess(
        &self,
        field: &CausalTensor<R>,
        zeroed_edges: &[usize],
        prescribed_edges: &[usize],
        reference_vertices: &[usize],
        constraint_rows: &[CutFaceConstraint<R>],
        opts: &HodgeDecomposeOptions<R>,
        x0: Option<&[R]>,
        lambda0: Option<&[R]>,
    ) -> Result<(LerayProjection<R>, Vec<R>), TopologyError> {
        if constraint_rows.is_empty() {
            // No weighted rows: the existing binary open path, bit-identical to the staircase.
            return Ok((
                self.leray_project_open_guess(
                    field,
                    zeroed_edges,
                    prescribed_edges,
                    reference_vertices,
                    opts,
                    x0,
                )?,
                Vec::new(),
            ));
        }

        let n1 = self.complex.num_cells(1);
        if field.len() != n1 {
            return Err(TopologyError::DimensionMismatch(format!(
                "leray_project_open_weighted: expected {} grade-1 coefficients, got {}",
                n1,
                field.len()
            )));
        }
        let metric = self.metric.as_ref().ok_or_else(|| {
            TopologyError::InvalidInput(
                "leray_project_open_weighted requires a metric; construct the manifold \
                 with a metric attached"
                    .to_string(),
            )
        })?;
        if !prescribed_edges.is_empty() && reference_vertices.is_empty() {
            return Err(TopologyError::InvalidInput(
                "leray_project_open_weighted: a prescribed inflow requires a reference (outflow) \
                 face to balance the net flux"
                    .to_string(),
            ));
        }
        let tolerance = resolve_cg_tolerance(opts.tolerance)?;
        let max_iter = opts.max_iterations.unwrap_or(1000);
        let n0 = self.complex.num_cells(0);

        // Full masses (divergence RHS, so prescribed flux counts) and free masses (operator excludes
        // every fixed edge — zeroed ∪ prescribed).
        let star1 = metric
            .hodge_star_matrix(self.complex(), 1)
            .map_err(|e| TopologyError::InvalidInput(format!("hodge star (grade 1): {e}")))?;
        let mass_full = super::stencil::build::star_diag(star1.as_ref(), n1);
        let mut mass_free = mass_full.clone();
        for &e in zeroed_edges.iter().chain(prescribed_edges.iter()) {
            if e >= n1 {
                return Err(TopologyError::InvalidInput(format!(
                    "leray_project_open_weighted: edge index {e} out of range ({n1} edges)"
                )));
            }
            mass_free[e] = R::zero();
        }

        // v: zero the zeroed edges; keep prescribed (inflow) edges at their field value.
        let mut v: Vec<R> = field.as_slice().to_vec();
        for &e in zeroed_edges {
            v[e] = R::zero();
        }

        // Normalised weighted rows over the FREE edges only (a fixed edge carries value 0, so it
        // drops from the row). Unit-norm rescaling leaves the projected `u` unchanged, conditioning
        // the dual block.
        let mut rows: Vec<(Vec<(usize, R)>, R)> = Vec::with_capacity(constraint_rows.len());
        for row in constraint_rows {
            let mut entries: Vec<(usize, R)> = Vec::with_capacity(row.entries().len());
            let mut norm_sq = R::zero();
            for &(e, w) in row.entries() {
                if e >= n1 {
                    return Err(TopologyError::InvalidInput(format!(
                        "leray_project_open_weighted: row edge index {e} out of range ({n1} edges)"
                    )));
                }
                if mass_free[e] == R::zero() {
                    continue;
                }
                entries.push((e, w));
                norm_sq += w * w;
            }
            if entries.is_empty() || norm_sq <= R::zero() {
                continue;
            }
            let inv = R::one() / norm_sq.sqrt();
            for (_, w) in entries.iter_mut() {
                *w *= inv;
            }
            rows.push((entries, row.target() * inv));
        }
        let m = rows.len();
        if m == 0 {
            return Ok((
                self.leray_project_open_guess(
                    field,
                    zeroed_edges,
                    prescribed_edges,
                    reference_vertices,
                    opts,
                    x0,
                )?,
                Vec::new(),
            ));
        }

        // Boundary CSR for ∂₁ and the weighted divergence ∂₁(mass ⊙ ·).
        let boundary = self.complex.boundary_matrix(1);
        let ptr = boundary.row_indices().to_vec();
        let cols = boundary.col_indices().to_vec();
        let vals = boundary.values().to_vec();
        drop(boundary);
        let div_with = |mass: &[R], w: &[R]| -> Vec<R> {
            let mut out = vec![R::zero(); n0];
            for (i, o) in out.iter_mut().enumerate() {
                for e in ptr[i]..ptr[i + 1] {
                    let c = cols[e];
                    let term = mass[c] * w[c];
                    if vals[e] >= 0 {
                        *o += term;
                    } else {
                        *o -= term;
                    }
                }
            }
            out
        };
        let c_lambda = |lambda: &[R]| -> Vec<R> {
            let mut edge = vec![R::zero(); n1];
            for (r, (entries, _)) in rows.iter().enumerate() {
                let lr = lambda[r];
                for &(e, w) in entries {
                    edge[e] += w * lr;
                }
            }
            edge
        };
        let ct_x = |edge: &[R]| -> Vec<R> {
            let mut out = vec![R::zero(); m];
            for (r, (entries, _)) in rows.iter().enumerate() {
                let mut s = R::zero();
                for &(e, w) in entries {
                    s += w * edge[e];
                }
                out[r] = s;
            }
            out
        };

        // Jacobi diagonal: φ block `Σ mass_free`; λ block `diag(Cᵀ M⁻¹ C) = Σ wₑ²/massₑ`.
        let mut diag = vec![R::zero(); n0 + m];
        for (i, d) in diag.iter_mut().take(n0).enumerate() {
            for e in ptr[i]..ptr[i + 1] {
                *d += mass_free[cols[e]];
            }
        }
        for (r, (entries, _)) in rows.iter().enumerate() {
            let mut s = R::zero();
            for &(e, w) in entries {
                s += w * w / mass_free[e];
            }
            diag[n0 + r] = s;
        }

        // Reference flood-fill (open gauge): only the reference-reachable component enforces the
        // divergence; the disconnected inlet ring is left unconstrained.
        let mut is_ref = vec![false; n0];
        for &r in reference_vertices {
            if r >= n0 {
                return Err(TopologyError::InvalidInput(format!(
                    "leray_project_open_weighted: reference vertex {r} out of range ({n0} vertices)"
                )));
            }
            is_ref[r] = true;
        }
        let mut live = vec![reference_vertices.is_empty(); n0];
        if !reference_vertices.is_empty() {
            let mut incident: Vec<Vec<usize>> = vec![Vec::new(); n1];
            for (i, inc) in ptr.windows(2).enumerate() {
                for e in inc[0]..inc[1] {
                    incident[cols[e]].push(i);
                }
            }
            let mut adj: Vec<Vec<usize>> = vec![Vec::new(); n0];
            for (e, ends) in incident.iter().enumerate() {
                if mass_free[e] > R::zero() && ends.len() == 2 {
                    adj[ends[0]].push(ends[1]);
                    adj[ends[1]].push(ends[0]);
                }
            }
            let mut stack: Vec<usize> = reference_vertices.to_vec();
            for &r in reference_vertices {
                live[r] = true;
            }
            while let Some(u) = stack.pop() {
                for &w in &adj[u] {
                    if !live[w] {
                        live[w] = true;
                        stack.push(w);
                    }
                }
            }
        }
        let eliminate = !reference_vertices.is_empty();
        // A φ row is inactive (eliminated / structurally null) when it has no free incidence, or
        // (open gauge) it is the reference or unreachable.
        let inactive: Vec<bool> = (0..n0)
            .map(|i| diag[i] == R::zero() || (eliminate && (is_ref[i] || !live[i])))
            .collect();

        // RHS = G f − c. φ block: ∂₁ M_full v with the gauge fix; λ block: Cᵀ v − b.
        let mut rhs = vec![R::zero(); n0 + m];
        {
            let phi_rhs = div_with(&mass_full, &v);
            if !eliminate {
                // Constrained gauge: zero null rows, subtract the block mean (RHS ⟂ constants).
                let mut block = 0usize;
                let mut block_sum = R::zero();
                for (i, &r) in phi_rhs.iter().enumerate() {
                    if inactive[i] {
                        rhs[i] = R::zero();
                    } else {
                        rhs[i] = r;
                        block += 1;
                        block_sum += r;
                    }
                }
                if block == 0 {
                    return Err(TopologyError::InvalidInput(
                        "leray_project_open_weighted: every edge is constrained".to_string(),
                    ));
                }
                let block_mean =
                    block_sum / <R as FromPrimitive>::from_usize(block).expect("count lifts");
                for (i, r) in rhs.iter_mut().enumerate().take(n0) {
                    if !inactive[i] {
                        *r -= block_mean;
                    }
                }
            } else {
                // Open gauge: enforce divergence only on the live, non-reference component.
                for (i, &r) in phi_rhs.iter().enumerate() {
                    rhs[i] = if inactive[i] { R::zero() } else { r };
                }
            }
            for (r, (entries, target)) in rows.iter().enumerate() {
                let mut s = R::zero();
                for &(e, w) in entries {
                    s += w * v[e];
                }
                rhs[n0 + r] = s - *target;
            }
        }

        // Augmented operator A y = G M⁻¹ Gᵀ y, y = [φ; λ]:
        //   φ rows: ∂₁(M_free dφ + C λ);   λ rows: Cᵀ dφ + Cᵀ M⁻¹ C λ — with the φ DOFs symmetrically
        //   eliminated on the inactive rows.
        let ones = vec![R::one(); n1];
        let apply = |y: &[R]| -> Vec<R> {
            let mut phi = y[..n0].to_vec();
            for (i, p) in phi.iter_mut().enumerate() {
                if inactive[i] {
                    *p = R::zero();
                }
            }
            let lambda = &y[n0..];
            let d_phi = self.exterior_derivative_of(&phi, 0);
            let mut grad = d_phi.into_vec();
            pad_or_truncate(&mut grad, n1);

            let c_lam = c_lambda(lambda);
            let mut edge = vec![R::zero(); n1];
            for (e, x) in edge.iter_mut().enumerate() {
                *x = mass_free[e] * grad[e] + c_lam[e];
            }
            let mut out = vec![R::zero(); n0 + m];
            let phi_out = div_with(&ones, &edge);
            for (i, o) in out.iter_mut().take(n0).enumerate() {
                *o = if inactive[i] { R::zero() } else { phi_out[i] };
            }
            let mut minv_clam = vec![R::zero(); n1];
            for (e, x) in minv_clam.iter_mut().enumerate() {
                if mass_free[e] != R::zero() {
                    *x = c_lam[e] / mass_free[e];
                }
            }
            let ct_grad = ct_x(&grad);
            let ct_minv = ct_x(&minv_clam);
            for r in 0..m {
                out[n0 + r] = ct_grad[r] + ct_minv[r];
            }
            out
        };

        // Warm start: seed the augmented guess `[φ; λ]` from the previous solve — the φ block from the
        // previous potential (masked to active DOFs), the λ block from the previous multipliers (used
        // only when its length matches the emitted-row count, so a changed body falls back to zero).
        // In a developed limit cycle both vary slowly, so the coupled CG converges in far fewer
        // iterations.
        let phi_warm = x0.is_some_and(|g| g.len() == n0);
        let lambda_warm = lambda0.is_some_and(|l| l.len() == m);
        let solve = if phi_warm || lambda_warm {
            let mut g = vec![R::zero(); n0 + m];
            if let Some(guess) = x0.filter(|g| g.len() == n0) {
                for (i, gi) in g.iter_mut().take(n0).enumerate() {
                    if !inactive[i] {
                        *gi = guess[i];
                    }
                }
            }
            if let Some(guess) = lambda0.filter(|l| l.len() == m) {
                g[n0..].copy_from_slice(guess);
            }
            deep_causality_sparse::cg_solve_preconditioned_from(
                apply, &diag, &rhs, &g, tolerance, max_iter,
            )
        } else {
            deep_causality_sparse::cg_solve_preconditioned(apply, &diag, &rhs, tolerance, max_iter)
        };
        let y = solve.map_err(|f| {
            TopologyError::HodgeDecompositionFailed(format!(
                "weighted projection solve did not converge in {} iterations (final residual {})",
                f.iterations, f.residual
            ))
        })?;
        let (phi_slice, lambda) = y.split_at(n0);
        let lambda_out = lambda.to_vec();
        let mut phi = phi_slice.to_vec();
        if !eliminate {
            subtract_mean_in_place(&mut phi);
        } else {
            for (i, p) in phi.iter_mut().enumerate() {
                if inactive[i] {
                    *p = R::zero();
                }
            }
        }

        // u = v − P_F(dφ + M⁻¹ C λ): the correction masked off every fixed edge.
        let d_phi = self.exterior_derivative_of(&phi, 0);
        let mut grad = d_phi.into_vec();
        pad_or_truncate(&mut grad, n1);
        let c_lam = c_lambda(lambda);
        let projected: Vec<R> = (0..n1)
            .map(|e| {
                if mass_free[e] == R::zero() {
                    v[e]
                } else {
                    v[e] - grad[e] - c_lam[e] / mass_free[e]
                }
            })
            .collect();

        let projected_t =
            CausalTensor::new(projected, vec![n1]).expect("1-D tensor allocation cannot fail");
        let potential_t =
            CausalTensor::new(phi, vec![n0]).expect("1-D tensor allocation cannot fail");
        Ok((LerayProjection::new(projected_t, potential_t), lambda_out))
    }

    fn leray_project_open_guess(
        &self,
        field: &CausalTensor<R>,
        zeroed_edges: &[usize],
        prescribed_edges: &[usize],
        reference_vertices: &[usize],
        opts: &HodgeDecomposeOptions<R>,
        x0: Option<&[R]>,
    ) -> Result<LerayProjection<R>, TopologyError> {
        if zeroed_edges.is_empty() && prescribed_edges.is_empty() && reference_vertices.is_empty() {
            return self.leray_project_opts(field, opts);
        }
        let n1 = self.complex.num_cells(1);
        if field.len() != n1 {
            return Err(TopologyError::DimensionMismatch(format!(
                "leray_project_open: expected {} grade-1 coefficients, got {}",
                n1,
                field.len()
            )));
        }
        let metric = self.metric.as_ref().ok_or_else(|| {
            TopologyError::InvalidInput(
                "leray_project_open requires a metric; construct the manifold \
                 with a metric attached"
                    .to_string(),
            )
        })?;
        if !prescribed_edges.is_empty() && reference_vertices.is_empty() {
            return Err(TopologyError::InvalidInput(
                "leray_project_open: a prescribed inflow requires a reference (outflow) face to \
                 balance the net flux"
                    .to_string(),
            ));
        }
        let tolerance = resolve_cg_tolerance(opts.tolerance)?;
        let max_iter = opts.max_iterations.unwrap_or(1000);
        let n0 = self.complex.num_cells(0);

        // Full grade-1 masses (for the divergence RHS, so prescribed flux counts) and the free
        // masses (the operator excludes every fixed edge — zeroed ∪ prescribed).
        let star1 = metric
            .hodge_star_matrix(self.complex(), 1)
            .map_err(|e| TopologyError::InvalidInput(format!("hodge star (grade 1): {e}")))?;
        let mass_full = super::stencil::build::star_diag(star1.as_ref(), n1);
        let mut mass_free = mass_full.clone();
        for &e in zeroed_edges.iter().chain(prescribed_edges.iter()) {
            if e >= n1 {
                return Err(TopologyError::InvalidInput(format!(
                    "leray_project_open: edge index {e} out of range ({n1} edges)"
                )));
            }
            mass_free[e] = R::zero();
        }

        // v: zero the zeroed edges; keep the prescribed (inflow) edges at their field value.
        let mut v: Vec<R> = field.as_slice().to_vec();
        for &e in zeroed_edges {
            v[e] = R::zero();
        }

        // Weighted divergence ∂₁(mass ⊙ ·) off the boundary CSR (mass selects free vs full).
        let boundary = self.complex.boundary_matrix(1);
        let ptr = boundary.row_indices().to_vec();
        let cols = boundary.col_indices().to_vec();
        let vals = boundary.values().to_vec();
        drop(boundary);
        let div_with = |mass: &[R], w: &[R]| -> Vec<R> {
            let mut out = vec![R::zero(); n0];
            for (i, o) in out.iter_mut().enumerate() {
                for e in ptr[i]..ptr[i + 1] {
                    let c = cols[e];
                    let term = mass[c] * w[c];
                    if vals[e] >= 0 {
                        *o += term;
                    } else {
                        *o -= term;
                    }
                }
            }
            out
        };
        // Jacobi diagonal from the free masses.
        let mut diag = vec![R::zero(); n0];
        for (i, d) in diag.iter_mut().enumerate() {
            for e in ptr[i]..ptr[i + 1] {
                *d += mass_free[cols[e]];
            }
        }

        // Reference mask and the free-edge connectivity. With a reference, only the component
        // reachable from it through free edges enforces the divergence; the disconnected inlet
        // ring (its sole interior link is the masked inflow edge) is left unconstrained.
        let mut is_ref = vec![false; n0];
        for &r in reference_vertices {
            if r >= n0 {
                return Err(TopologyError::InvalidInput(format!(
                    "leray_project_open: reference vertex {r} out of range ({n0} vertices)"
                )));
            }
            is_ref[r] = true;
        }
        let mut live = vec![reference_vertices.is_empty(); n0];
        if !reference_vertices.is_empty() {
            // Vertex adjacency over free edges, inverted from the vertex→edge CSR.
            let mut incident: Vec<Vec<usize>> = vec![Vec::new(); n1];
            for (i, inc) in ptr.windows(2).enumerate() {
                for e in inc[0]..inc[1] {
                    incident[cols[e]].push(i);
                }
            }
            let mut adj: Vec<Vec<usize>> = vec![Vec::new(); n0];
            for (e, ends) in incident.iter().enumerate() {
                if mass_free[e] > R::zero() && ends.len() == 2 {
                    adj[ends[0]].push(ends[1]);
                    adj[ends[1]].push(ends[0]);
                }
            }
            let mut stack: Vec<usize> = reference_vertices.to_vec();
            for &r in reference_vertices {
                live[r] = true;
            }
            while let Some(u) = stack.pop() {
                for &w in &adj[u] {
                    if !live[w] {
                        live[w] = true;
                        stack.push(w);
                    }
                }
            }
        }

        // RHS = ∂ M₁ v (full masses ⇒ prescribed flux counts).
        let mut wrhs = div_with(&mass_full, &v);
        if reference_vertices.is_empty() {
            // Closed/constrained gauge: zero null rows, subtract the mean over the connected block.
            let mut block = 0usize;
            let mut block_sum = R::zero();
            for (r, d) in wrhs.iter_mut().zip(diag.iter()) {
                if *d == R::zero() {
                    *r = R::zero();
                } else {
                    block += 1;
                    block_sum += *r;
                }
            }
            if block == 0 {
                return Err(TopologyError::InvalidInput(
                    "leray_project_open: every edge is constrained".to_string(),
                ));
            }
            let block_mean =
                block_sum / <R as FromPrimitive>::from_usize(block).expect("count lifts");
            for (r, d) in wrhs.iter_mut().zip(diag.iter()) {
                if *d != R::zero() {
                    *r -= block_mean;
                }
            }
        } else {
            // Open gauge: enforce divergence only on the live (reference-reachable) component; the
            // reference itself is pinned (φ = 0), so no mean subtraction.
            for (i, (r, d)) in wrhs.iter_mut().zip(diag.iter()).enumerate() {
                if !live[i] || is_ref[i] || *d == R::zero() {
                    *r = R::zero();
                }
            }
        }

        // A φ = ∂₁(M₁|_F ⊙ d₀ φ). With a reference, the pinned and non-live DOFs are symmetrically
        // eliminated (input and output rows zeroed ⇒ they stay at φ = 0 and never couple in).
        let eliminate = !reference_vertices.is_empty();
        let apply = |phi: &[R]| -> Vec<R> {
            let mut p = phi.to_vec();
            if eliminate {
                for (i, pv) in p.iter_mut().enumerate() {
                    if is_ref[i] || !live[i] {
                        *pv = R::zero();
                    }
                }
            }
            let d_phi = self.exterior_derivative_of(&p, 0);
            let mut grad = d_phi.into_vec();
            pad_or_truncate(&mut grad, n1);
            let mut out = div_with(&mass_free, &grad);
            if eliminate {
                for (i, o) in out.iter_mut().enumerate() {
                    if is_ref[i] || !live[i] {
                        *o = R::zero();
                    }
                }
            }
            out
        };
        // Warm start: a caller-supplied initial guess (the previous solve's potential) seeds CG,
        // which converges in far fewer iterations for a slowly varying right-hand side. The guess is
        // masked to the active DOFs (pinned and non-live vertices stay at zero) so it cannot pollute
        // the eliminated rows. The result is the same solution to tolerance, independent of `x0`.
        let solve = match x0 {
            Some(guess) if guess.len() == n0 => {
                let mut g = guess.to_vec();
                for (i, gi) in g.iter_mut().enumerate() {
                    if diag[i] == R::zero() || (eliminate && (is_ref[i] || !live[i])) {
                        *gi = R::zero();
                    }
                }
                deep_causality_sparse::cg_solve_preconditioned_from(
                    apply, &diag, &wrhs, &g, tolerance, max_iter,
                )
            }
            _ => deep_causality_sparse::cg_solve_preconditioned(
                apply, &diag, &wrhs, tolerance, max_iter,
            ),
        };
        let mut phi = solve.map_err(|f| {
            TopologyError::HodgeDecompositionFailed(format!(
                "open projection solve did not converge in {} iterations (final residual {})",
                f.iterations, f.residual
            ))
        })?;
        if reference_vertices.is_empty() {
            subtract_mean_in_place(&mut phi);
        } else {
            for (i, pv) in phi.iter_mut().enumerate() {
                if is_ref[i] || !live[i] {
                    *pv = R::zero();
                }
            }
        }

        // u = v − P_F dφ: gradient correction masked off every fixed edge.
        let d_phi = self.exterior_derivative_of(&phi, 0);
        let mut grad = d_phi.into_vec();
        pad_or_truncate(&mut grad, n1);
        for &e in zeroed_edges.iter().chain(prescribed_edges.iter()) {
            grad[e] = R::zero();
        }
        let projected: Vec<R> = v.iter().zip(grad.iter()).map(|(w, g)| *w - *g).collect();

        let projected_t =
            CausalTensor::new(projected, vec![n1]).expect("1-D tensor allocation cannot fail");
        let potential_t =
            CausalTensor::new(phi, vec![n0]).expect("1-D tensor allocation cannot fail");
        Ok(LerayProjection::new(projected_t, potential_t))
    }

    /// Convenience agreement check used by the verification suite: the
    /// gradient part removed by [`Self::leray_project`] must match the exact
    /// (`dα`) component of the full [`Self::hodge_decompose`] on the same
    /// field. Exposed as a method so downstream crates can assert the
    /// half-vs-full consistency without reimplementing either side.
    ///
    /// Returns the maximum absolute difference between `ω − P(ω)` and the
    /// full decomposition's exact component.
    pub fn leray_vs_hodge_gradient_gap(
        &self,
        field: &CausalTensor<R>,
        opts: &HodgeDecomposeOptions<R>,
    ) -> Result<R, TopologyError> {
        let projection = self.leray_project_opts(field, opts)?;
        let full: HodgeDecomposition<R> = self.hodge_decompose_opts(field, 1, opts)?;

        let gap = field
            .as_slice()
            .iter()
            .zip(projection.projected().as_slice().iter())
            .zip(full.exact().as_slice().iter())
            .map(|((w, p), a)| ((*w - *p) - *a).abs())
            .fold(R::zero(), |m, v| if v > m { v } else { m });

        Ok(gap)
    }
}
