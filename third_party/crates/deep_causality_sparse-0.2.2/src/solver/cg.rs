/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Matrix-free Conjugate Gradient solver.
//!
//! Solves `A x = b` for a symmetric positive semi-definite operator `A`
//! provided as a closure `apply: Fn(&[R]) -> Vec<R>` returning `A · v`. The
//! operator itself is never assembled as a matrix; this lets callers reuse
//! existing matrix-free operator-application pipelines (for example a graph
//! Laplacian applied without ever forming the dense matrix).
//!
//! Convergence is measured against the relative residual `‖r‖ / ‖b‖` (with the
//! `‖b‖ = 0` corner case falling back to the absolute residual). The caller
//! supplies a tolerance, typically derived from the precision backend's machine
//! epsilon.
//!
//! The solver is generic over any [`RealField`] precision (`f32`, `f64`,
//! `Float106`, …) and adds no external numeric dependency.

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

/// Reason a CG solve failed to converge.
///
/// Returned in the `Err` arm of [`cg_solve`] when the iteration budget is
/// exhausted, an algebraic breakdown (`pᵀ A p = 0` with a non-zero search
/// direction) occurs, or the operator returns a vector of the wrong length.
#[derive(Debug, Clone)]
pub struct CgFailure<R: RealField> {
    /// Number of iterations performed before the failure was reported.
    pub iterations: usize,
    /// Residual norm `‖r‖` at the point of failure.
    pub residual: R,
}

/// Run Conjugate Gradient on a symmetric positive semi-definite operator.
///
/// # Arguments
/// * `apply` — closure computing `A · v` for arbitrary `v`.
/// * `b` — right-hand side vector.
/// * `tolerance` — relative residual threshold for convergence.
/// * `max_iterations` — iteration budget.
///
/// # Returns
/// `Ok(x)` if the residual fell to or below `tolerance · ‖b‖`, `Err(CgFailure)`
/// if the iteration budget was exhausted or a numerical breakdown (`pᵀ A p = 0`
/// with a non-zero search direction) occurred.
pub fn cg_solve<R, Apply>(
    apply: Apply,
    b: &[R],
    tolerance: R,
    max_iterations: usize,
) -> Result<Vec<R>, CgFailure<R>>
where
    R: RealField + FromPrimitive,
    Apply: Fn(&[R]) -> Vec<R>,
{
    let n = b.len();
    let mut x = vec![R::zero(); n];

    // r₀ = b - A·x₀ = b  (since x₀ = 0)
    let mut r: Vec<R> = b.to_vec();
    let mut p = r.clone();
    let mut rsold: R = dot(&r, &r);

    let b_norm = dot(b, b).sqrt();
    let abs_tol = if b_norm == R::zero() {
        tolerance
    } else {
        tolerance * b_norm
    };

    // `<=` so an exact solution (residual exactly at the tolerance, including the
    // `b = 0`, `tolerance = 0` case where both are zero) converges immediately
    // rather than entering the loop and tripping the `pᵀ A p = 0` breakdown.
    if rsold.sqrt() <= abs_tol {
        return Ok(x);
    }

    for iter in 0..max_iterations {
        let ap = apply(&p);
        if ap.len() != n {
            return Err(CgFailure {
                iterations: iter,
                residual: rsold.sqrt(),
            });
        }
        let pap = dot(&p, &ap);
        // Algebraic breakdown only. A relative threshold here would either
        // (a) fire spuriously on the very small `pap` values that arise at
        // Float106 / f32 precision near convergence, or (b) miss true
        // breakdowns at large magnitudes. Exact-zero is the only check that
        // is precision-invariant; non-convergence past `max_iterations`
        // catches every other failure mode.
        if pap == R::zero() {
            return Err(CgFailure {
                iterations: iter,
                residual: rsold.sqrt(),
            });
        }
        let alpha = rsold / pap;
        for i in 0..n {
            x[i] += alpha * p[i];
            r[i] -= alpha * ap[i];
        }
        let rsnew = dot(&r, &r);
        if rsnew.sqrt() <= abs_tol {
            return Ok(x);
        }
        let beta = rsnew / rsold;
        for i in 0..n {
            p[i] = r[i] + beta * p[i];
        }
        rsold = rsnew;
    }

    Err(CgFailure {
        iterations: max_iterations,
        residual: rsold.sqrt(),
    })
}

/// Jacobi-preconditioned CG with a caller-supplied initial guess `x0` (warm start).
///
/// Identical to [`cg_solve_preconditioned`] except the iteration starts from `x0` instead of the
/// zero vector, so a good guess (the previous step's solution for a slowly varying right-hand side)
/// converges in far fewer iterations. The result is the same solution to within `tolerance`,
/// independent of `x0`. `x0` must have the same length as `b`; a wrong length is reported as a
/// failure on the first operator application.
///
/// # Errors
/// `Err(CgFailure)` if the iteration budget is exhausted or a numerical breakdown
/// (`pᵀ A p = 0` with a non-zero search direction) occurs.
pub fn cg_solve_preconditioned_from<R, Apply>(
    apply: Apply,
    diag_a: &[R],
    b: &[R],
    x0: &[R],
    tolerance: R,
    max_iterations: usize,
) -> Result<Vec<R>, CgFailure<R>>
where
    R: RealField + FromPrimitive,
    Apply: Fn(&[R]) -> Vec<R>,
{
    let n = b.len();
    if x0.len() != n {
        return Err(CgFailure {
            iterations: 0,
            residual: dot(b, b).sqrt(),
        });
    }
    let mut x = x0.to_vec();

    let precond = |r: &[R]| -> Vec<R> {
        r.iter()
            .zip(diag_a.iter())
            .map(|(&ri, &di)| if di > R::zero() { ri / di } else { ri })
            .collect()
    };

    // r₀ = b − A·x₀ (the one extra operator application warm start costs).
    let ax0 = apply(&x);
    if ax0.len() != n {
        return Err(CgFailure {
            iterations: 0,
            residual: dot(b, b).sqrt(),
        });
    }
    let mut r: Vec<R> = b.iter().zip(ax0.iter()).map(|(&bi, &ai)| bi - ai).collect();
    let mut z = precond(&r);
    let mut p = z.clone();
    let mut rz_old = dot(&r, &z);

    let b_norm = dot(b, b).sqrt();
    let abs_tol = if b_norm == R::zero() {
        tolerance
    } else {
        tolerance * b_norm
    };
    if dot(&r, &r).sqrt() <= abs_tol {
        return Ok(x);
    }

    for iter in 0..max_iterations {
        let ap = apply(&p);
        if ap.len() != n {
            return Err(CgFailure {
                iterations: iter,
                residual: dot(&r, &r).sqrt(),
            });
        }
        let pap = dot(&p, &ap);
        if pap == R::zero() {
            return Err(CgFailure {
                iterations: iter,
                residual: dot(&r, &r).sqrt(),
            });
        }
        let alpha = rz_old / pap;
        for i in 0..n {
            x[i] += alpha * p[i];
            r[i] -= alpha * ap[i];
        }
        if dot(&r, &r).sqrt() <= abs_tol {
            return Ok(x);
        }
        z = precond(&r);
        let rz_new = dot(&r, &z);
        let beta = rz_new / rz_old;
        for i in 0..n {
            p[i] = z[i] + beta * p[i];
        }
        rz_old = rz_new;
    }

    Err(CgFailure {
        iterations: max_iterations,
        residual: dot(&r, &r).sqrt(),
    })
}

#[inline]
fn dot<R>(a: &[R], b: &[R]) -> R
where
    R: RealField,
{
    a.iter()
        .zip(b.iter())
        .map(|(&x, &y)| x * y)
        .fold(R::zero(), |acc, t| acc + t)
}

/// Jacobi-preconditioned conjugate gradient: solves `A x = b` for symmetric
/// positive (semi)definite `A` with the diagonal preconditioner
/// `M⁻¹ = diag(1/diag_a)`. Entries of `diag_a` at or below zero are treated
/// as `1` (no preconditioning on that row), which keeps the preconditioner
/// SPD for clipped or partially-degenerate diagonals.
///
/// Convergence is reported against the same unpreconditioned relative
/// residual as [`cg_solve`], so the two are directly comparable; the
/// preconditioner only changes the search directions.
///
/// # Arguments
/// * `apply` — closure computing `A · v` for arbitrary `v`.
/// * `diag_a` — the diagonal of `A` (the Jacobi preconditioner).
/// * `b` — right-hand side vector.
/// * `tolerance` — relative residual threshold for convergence.
/// * `max_iterations` — iteration budget.
///
/// # Errors
/// `Err(CgFailure)` if the iteration budget is exhausted or a numerical
/// breakdown (`pᵀ A p = 0` with a non-zero search direction) occurs.
pub fn cg_solve_preconditioned<R, Apply>(
    apply: Apply,
    diag_a: &[R],
    b: &[R],
    tolerance: R,
    max_iterations: usize,
) -> Result<Vec<R>, CgFailure<R>>
where
    R: RealField + FromPrimitive,
    Apply: Fn(&[R]) -> Vec<R>,
{
    let n = b.len();
    let mut x = vec![R::zero(); n];

    let precond = |r: &[R]| -> Vec<R> {
        r.iter()
            .zip(diag_a.iter())
            .map(|(&ri, &di)| if di > R::zero() { ri / di } else { ri })
            .collect()
    };

    let mut r = b.to_vec();
    let mut z = precond(&r);
    let mut p = z.clone();
    let mut rz_old = dot(&r, &z);

    let b_norm = dot(b, b).sqrt();
    let abs_tol = if b_norm == R::zero() {
        tolerance
    } else {
        tolerance * b_norm
    };
    if dot(&r, &r).sqrt() <= abs_tol {
        return Ok(x);
    }

    for iter in 0..max_iterations {
        let ap = apply(&p);
        if ap.len() != n {
            return Err(CgFailure {
                iterations: iter,
                residual: dot(&r, &r).sqrt(),
            });
        }
        let pap = dot(&p, &ap);
        if pap == R::zero() {
            return Err(CgFailure {
                iterations: iter,
                residual: dot(&r, &r).sqrt(),
            });
        }
        let alpha = rz_old / pap;
        for i in 0..n {
            x[i] += alpha * p[i];
            r[i] -= alpha * ap[i];
        }
        if dot(&r, &r).sqrt() <= abs_tol {
            return Ok(x);
        }
        z = precond(&r);
        let rz_new = dot(&r, &z);
        let beta = rz_new / rz_old;
        for i in 0..n {
            p[i] = z[i] + beta * p[i];
        }
        rz_old = rz_new;
    }

    Err(CgFailure {
        iterations: max_iterations,
        residual: dot(&r, &r).sqrt(),
    })
}
