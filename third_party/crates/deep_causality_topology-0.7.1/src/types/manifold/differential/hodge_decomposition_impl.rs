/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Discrete Hodge–Helmholtz decomposition implementation.
//!
//! Given a k-form ω on a `Manifold<K, R>` whose `K::Metric: HasHodgeStar<R>`, the
//! decomposition produces three pairwise-orthogonal components
//!
//! ```text
//! ω = d α  +  δ β  +  h
//! ```
//!
//! via two sequential discrete Poisson solves and a residual computation:
//!
//! 1. Solve `Δ_{k-1} φ_α = δ ω` for the (k-1)-form potential `φ_α`; set `α = d φ_α`.
//! 2. Solve `Δ_{k+1} ψ_β = d ω` for the (k+1)-form potential `ψ_β`; set `β = δ ψ_β`.
//! 3. `h = ω − α − β`.
//!
//! The Poisson solves run through the matrix-free CG solver
//! [`deep_causality_sparse::cg_solve`], which composes against `Manifold::laplacian`
//! rather than assembling `Δ_k` as a `CsrMatrix`. The gauge-fixing mean subtraction
//! lives in [`crate::utils::cg_solver`]. The gauge non-uniqueness at grade 0 (where
//! the constant functions are always harmonic) is fixed by subtracting the mean from
//! `φ_α` per the standard DEC convention.
//!
//! **Periodic lattices** (supersedes Risk 1 of the archived
//! `add-hodge-decomposition` change): on tori the α/β-step operators have
//! nontrivial harmonic kernels (`β_k > 0`), but their right-hand sides (`δω`,
//! `dω`) are M-orthogonal to those kernels in exact arithmetic, so the CG Krylov
//! space stays in `range(Δ)` and the consistent singular solves converge. This is
//! pinned by the periodic-lattice test suite (2D/3D tori, mixed periodicity, and
//! a 16×16 drift canary in `tests/types/manifold/leray_tests.rs`); constructive
//! harmonic-basis deflation remains the documented fallback if larger scales ever
//! stagnate. See the `add-dec-solver-foundations` change, design D6.

use core::fmt::{Debug, Display};

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use crate::errors::topology_error::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::hodge_decomposition::HodgeDecomposition;
use crate::types::manifold::Manifold;
use crate::utils::cg_solver::subtract_mean_in_place;
use deep_causality_par::MaybeParallel;
use deep_causality_sparse::{CgFailure, cg_solve, cg_solve_preconditioned};

/// Caller-tunable knobs for `Manifold::hodge_decompose_opts`.
///
/// Both fields are `Option`; `None` means "use the default derived from the precision
/// backend's machine epsilon". The default tolerance is
/// `R::from_f64(1e-10).unwrap_or_else(R::epsilon)`; the default iteration budget is
/// `1000`, adequate for the lattice sizes the downstream fluid pipeline targets
/// (≤ 256³).
#[derive(Debug, Clone)]
pub struct HodgeDecomposeOptions<R: RealField> {
    /// Relative-residual convergence threshold for the iterative solve.
    pub tolerance: Option<R>,
    /// Maximum CG iteration count before reporting non-convergence.
    pub max_iterations: Option<usize>,
}

impl<R: RealField> Default for HodgeDecomposeOptions<R> {
    fn default() -> Self {
        Self {
            tolerance: None,
            max_iterations: None,
        }
    }
}

/// Private control-flow enum carrying typed `R`-precision failure detail inside the
/// `hodge_decompose` impl. Converted to a stringly-typed `TopologyError` at the `Err`
/// boundary so the public error surface stays free of any precision-bearing type
/// parameter. Never crosses the module boundary.
enum HodgeFailReason<R: RealField> {
    Nonconvergence { iterations: usize, residual: R },
    GradeOutOfRange { k: usize, max_dim: usize },
    DimensionMismatch { expected: usize, actual: usize },
    MissingMetric,
}

impl<R: RealField + Display> HodgeFailReason<R> {
    fn into_topology_error(self) -> TopologyError {
        match self {
            Self::Nonconvergence {
                iterations,
                residual,
            } => TopologyError::HodgeDecompositionFailed(format!(
                "iterative solve did not converge in {} iterations (final residual {})",
                iterations, residual
            )),
            Self::GradeOutOfRange { k, max_dim } => TopologyError::HodgeDecompositionFailed(
                format!("grade {} exceeds manifold max_dim {}", k, max_dim),
            ),
            Self::DimensionMismatch { expected, actual } => {
                TopologyError::HodgeDecompositionFailed(format!(
                    "field length {} does not match expected {}",
                    actual, expected
                ))
            }
            Self::MissingMetric => TopologyError::HodgeDecompositionFailed(
                "manifold has no metric attached".to_string(),
            ),
        }
    }
}

impl<K, R> Manifold<K, R>
where
    K: ChainComplex + Clone,
    K::Metric: HasHodgeStar<R, Complex = K> + Clone,
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + Debug + Display,
{
    /// Discrete Hodge–Helmholtz decomposition of a k-form `field` on this manifold,
    /// using default tolerance and iteration budget.
    ///
    /// See [`HodgeDecomposeOptions`] for the override path and the module-level doc
    /// for the algorithm.
    ///
    /// # Errors
    /// Returns `TopologyErrorEnum::HodgeDecompositionFailed(msg)` if:
    /// - `k > self.complex.max_dim()` (grade out of range),
    /// - `field.len() != self.complex.num_cells(k)` (dimension mismatch),
    /// - the manifold has no metric attached,
    /// - or the iterative solve does not converge within the iteration budget.
    pub fn hodge_decompose(
        &self,
        field: &CausalTensor<R>,
        k: usize,
    ) -> Result<HodgeDecomposition<R>, TopologyError> {
        self.hodge_decompose_opts(field, k, &HodgeDecomposeOptions::default())
    }

    /// Discrete Hodge–Helmholtz decomposition with caller-supplied tolerance and
    /// iteration budget. See [`hodge_decompose`](Self::hodge_decompose) for the
    /// default-options entry point and the failure modes.
    pub fn hodge_decompose_opts(
        &self,
        field: &CausalTensor<R>,
        k: usize,
        opts: &HodgeDecomposeOptions<R>,
    ) -> Result<HodgeDecomposition<R>, TopologyError> {
        let max_dim = self.complex.max_dim();
        if k > max_dim {
            return Err(HodgeFailReason::<R>::GradeOutOfRange { k, max_dim }.into_topology_error());
        }
        let expected_len = self.complex.num_cells(k);
        let actual_len = field.as_slice().len();
        if actual_len != expected_len {
            return Err(HodgeFailReason::<R>::DimensionMismatch {
                expected: expected_len,
                actual: actual_len,
            }
            .into_topology_error());
        }
        if self.metric.is_none() {
            return Err(HodgeFailReason::<R>::MissingMetric.into_topology_error());
        }

        // Tolerance defaulting (per-backend epsilon floor) and the
        // non-positive-tolerance rejection live in `resolve_cg_tolerance`,
        // shared with `leray_project_opts`.
        let tolerance = resolve_cg_tolerance(opts.tolerance)?;
        let max_iter = opts.max_iterations.unwrap_or(1000);

        let omega: Vec<R> = field.as_slice().to_vec();
        let n_k = expected_len;

        // --- α = d φ_α with Δ_{k-1} φ_α = δω ---
        let alpha: Vec<R> = if k == 0 {
            vec![R::zero(); n_k]
        } else {
            let n_km1 = self.complex.num_cells(k - 1);
            let delta_omega = self.codifferential_of(&omega, k);
            let mut rhs = delta_omega.as_slice().to_vec();
            pad_or_truncate(&mut rhs, n_km1);
            // Gauge note: the grade-0 kernel projection happens inside
            // `solve_laplacian` on the *mass-weighted* RHS — subtracting
            // the Euclidean mean here would break M-consistency on
            // boundary-clipped lattices (the wall-hodge-star change).

            let mut phi_alpha = solve_laplacian(self, k - 1, &rhs, tolerance, max_iter)?;
            if k - 1 == 0 {
                subtract_mean_in_place(&mut phi_alpha);
            }

            let alpha_tensor = self.exterior_derivative_of(&phi_alpha, k - 1);
            let mut alpha = alpha_tensor.as_slice().to_vec();
            pad_or_truncate(&mut alpha, n_k);
            alpha
        };

        // --- β = δ ψ_β with Δ_{k+1} ψ_β = dω ---
        let beta: Vec<R> = if k >= max_dim {
            vec![R::zero(); n_k]
        } else {
            let n_kp1 = self.complex.num_cells(k + 1);
            let d_omega = self.exterior_derivative_of(&omega, k);
            let mut rhs = d_omega.as_slice().to_vec();
            pad_or_truncate(&mut rhs, n_kp1);

            let psi_beta = solve_laplacian(self, k + 1, &rhs, tolerance, max_iter)?;

            let beta_tensor = self.codifferential_of(&psi_beta, k + 1);
            let mut beta = beta_tensor.as_slice().to_vec();
            pad_or_truncate(&mut beta, n_k);
            beta
        };

        // --- h = ω − α − β ---
        let harmonic: Vec<R> = (0..n_k).map(|i| omega[i] - alpha[i] - beta[i]).collect();

        let exact_t = CausalTensor::new(alpha, vec![n_k]).unwrap();
        let co_exact_t = CausalTensor::new(beta, vec![n_k]).unwrap();
        let harmonic_t = CausalTensor::new(harmonic, vec![n_k]).unwrap();

        Ok(HodgeDecomposition::new(exact_t, co_exact_t, harmonic_t, k))
    }
}

/// Solve `Δ_grade x = rhs` matrix-free via CG on this manifold.
///
/// Grade 0 on a fully periodic uniform lattice with Euclidean per-axis
/// spacings dispatches to the spectral (FFT) solve instead — exact to
/// rounding, no iteration, `tolerance`/`max_iter` unused on that path.
/// See [`super::spectral_poisson`].
pub(super) fn solve_laplacian<K, R>(
    manifold: &Manifold<K, R>,
    grade: usize,
    rhs: &[R],
    tolerance: R,
    max_iter: usize,
) -> Result<Vec<R>, TopologyError>
where
    K: ChainComplex + Clone,
    K::Metric: HasHodgeStar<R, Complex = K> + Clone,
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + Debug + Display,
{
    if grade == 0
        && let Some((shape, periodic)) = manifold.complex().uniform_lattice_layout()
        && let Some(spacings) = manifold
            .metric
            .as_ref()
            .and_then(|m| m.uniform_axis_spacings())
    {
        if periodic.iter().all(|&p| p) {
            return super::spectral_poisson::spectral_poisson_solve(&shape, &spacings, rhs);
        }
        // Wall-bounded box: the boundary-corrected Δ₀ diagonalizes in the
        // DCT-I basis along wall axes (extent ≥ 2 required per axis).
        if periodic
            .iter()
            .zip(shape.iter())
            .all(|(&p, &n)| p || n >= 2)
        {
            return super::neumann_poisson::neumann_poisson_solve(
                &shape, &periodic, &spacings, rhs,
            );
        }
    }

    let n = rhs.len();

    // Warm the parent complex's boundary/coboundary memos once: every CG
    // iteration clones the complex into a temp manifold, and a warm parent
    // makes each clone a flat copy of the cached CSRs instead of a rebuild
    // per iteration. These are exactly the matrices `laplacian(grade)`
    // reads (dδ needs ∂_grade and δ_{grade−1}; δd needs δ_grade and
    // ∂_{grade+1}).
    {
        let complex = manifold.complex();
        if grade > 0 {
            let _ = complex.boundary_matrix(grade);
            let _ = complex.coboundary_matrix(grade - 1);
        }
        if grade < complex.max_dim() {
            let _ = complex.coboundary_matrix(grade);
            let _ = complex.boundary_matrix(grade + 1);
        }
    }

    // CG runs in the Euclidean inner product, but Δ_k = M_k⁻¹∂M… is only
    // Euclidean-symmetric when the grade's mass diagonal is constant —
    // true on unit/uniform interiors, false once the boundary-corrected
    // star clips dual volumes at walls. Solve the mass-weighted normal
    // form instead: M_k·Δ_k is symmetric positive (semi)definite for any
    // positive diagonal masses, with the same solution for the weighted
    // RHS M_k·rhs. On constant-mass lattices this is a pure rescaling of
    // the old system.
    let mass_k: Vec<R> = {
        let metric = manifold.metric.as_ref().ok_or_else(|| {
            TopologyError::InvalidInput(
                "solve_laplacian requires a metric; construct the manifold with a metric attached"
                    .to_string(),
            )
        })?;
        let star = metric
            .hodge_star_matrix(manifold.complex(), grade)
            .map_err(|e| TopologyError::InvalidInput(format!("hodge star (grade {grade}): {e}")))?;
        super::stencil::build::star_diag(star.as_ref(), n)
    };

    // Apply M_k·Δ directly on the iterate: no temporary manifold, no
    // data-slab copy — one sparse-operator composition per CG iteration.
    let apply = |v: &[R]| -> Vec<R> {
        let result = manifold.laplacian_of(v, grade);
        let mut out = result.into_vec();
        pad_or_truncate(&mut out, n);
        for (o, m) in out.iter_mut().zip(mass_k.iter()) {
            *o *= *m;
        }
        out
    };
    let mut weighted_rhs: Vec<R> = rhs
        .iter()
        .zip(mass_k.iter())
        .map(|(r, m)| *r * *m)
        .collect();
    // Grade 0: the constants are always in `ker(M₀Δ₀)`; project the
    // weighted RHS against them (the consistent-gauge condition is
    // `Σ M₀·rhs = 0`, exact in theory — this removes rounding drift).
    // Grade 0 also gets the Jacobi preconditioner: the weighted diagonal
    // is `diag(M₀Δ₀)_i = Σ_{e∋i} M₁[e]` (incidence entries are ±1), read
    // straight off the boundary CSR — the boundary-corrected diagonal of
    // the neumann-poisson capability.
    let solve_result = if grade == 0 {
        subtract_mean_in_place(&mut weighted_rhs);
        let mass_1: Vec<R> = {
            let metric = manifold
                .metric
                .as_ref()
                .expect("metric presence verified above");
            let star = metric
                .hodge_star_matrix(manifold.complex(), 1)
                .map_err(|e| TopologyError::InvalidInput(format!("hodge star (grade 1): {e}")))?;
            super::stencil::build::star_diag(star.as_ref(), manifold.complex().num_cells(1))
        };
        let boundary = manifold.complex().boundary_matrix(1);
        let ptr = boundary.row_indices();
        let cols = boundary.col_indices();
        let mut diag = vec![R::zero(); n];
        for (i, dslot) in diag
            .iter_mut()
            .enumerate()
            .take(ptr.len().saturating_sub(1))
        {
            for e in ptr[i]..ptr[i + 1] {
                *dslot += mass_1[cols[e]];
            }
        }
        cg_solve_preconditioned(apply, &diag, &weighted_rhs, tolerance, max_iter)
    } else {
        cg_solve(apply, &weighted_rhs, tolerance, max_iter)
    };
    match solve_result {
        Ok(x) => Ok(x),
        Err(CgFailure {
            iterations,
            residual,
        }) => Err(HodgeFailReason::Nonconvergence {
            iterations,
            residual,
        }
        .into_topology_error()),
    }
}

pub(super) fn pad_or_truncate<R: RealField>(v: &mut Vec<R>, target_len: usize) {
    if v.len() < target_len {
        v.resize(target_len, R::zero());
    } else if v.len() > target_len {
        v.truncate(target_len);
    }
}

/// Resolve the CG tolerance from caller options, applying the per-backend
/// epsilon floor, and reject non-positive values. Shared by
/// `hodge_decompose_opts` and `leray_project_opts`.
pub(super) fn resolve_cg_tolerance<R>(requested: Option<R>) -> Result<R, TopologyError>
where
    R: RealField + MaybeParallel + FromPrimitive + Display,
{
    let tolerance = requested.unwrap_or_else(|| {
        // Default convergence threshold: tight relative residual (1e-10),
        // clamped from below to `R::epsilon() * 100` so the threshold stays
        // representable at low-precision backends.
        let candidate = <R as FromPrimitive>::from_f64(1e-10).unwrap_or_else(R::epsilon);
        let floor = R::epsilon() * <R as FromPrimitive>::from_f64(100.0).unwrap_or(R::one());
        if candidate > floor { candidate } else { floor }
    });
    if tolerance <= R::zero() {
        return Err(TopologyError::HodgeDecompositionFailed(format!(
            "tolerance must be strictly positive, got {}",
            tolerance
        )));
    }
    Ok(tolerance)
}
