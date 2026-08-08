/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensorError;
use crate::types::causal_tensor::CausalTensor;
use deep_causality_algebra::{ConjugateScalar, Real};
use deep_causality_num::{One, Zero};

/// The real magnitude type of a conjugate scalar.
type Re<T> = <T as ConjugateScalar>::Real;

/// Eigendecomposition of a **Hermitian** row-major `n×n` matrix by cyclic Jacobi rotations
/// (`Uᴴ A U`). Returns `(eigenvalues, V)` where the columns of the row-major `n×n` `V` are the
/// eigenvectors: `A = V diag(λ) Vᴴ`. Eigenvalues are real (returned as `T`) and unsorted. For a real
/// scalar the phase `ρ = ±1` and this reduces to the ordinary real-symmetric Jacobi.
///
/// # Reference
/// G. H. Golub and C. F. Van Loan, *Matrix Computations*, 4th ed. (Johns Hopkins Univ. Press,
/// 2013), §8.5 (Jacobi methods).
pub(crate) fn sym_eig<T: ConjugateScalar>(mat: &[T], n: usize) -> (Vec<T>, Vec<T>) {
    let mut a = mat.to_vec();
    let mut v = vec![T::zero(); n * n];
    for i in 0..n {
        v[i * n + i] = T::one();
    }
    let one = Re::<T>::one();
    let two = one + one;
    // Relative stopping threshold: scale the ε² off-diagonal budget by ‖A‖²_F,
    // which is invariant under the (orthogonal) Jacobi rotations, so it is
    // computed once from the input. An absolute ε² test never terminates for
    // large-magnitude matrices and burns the full sweep budget every time.
    let eps2 = Re::<T>::epsilon() * Re::<T>::epsilon();
    let norm_sq = a
        .iter()
        .fold(Re::<T>::zero(), |acc, x| acc + x.modulus_squared());
    // If ‖A‖²_F overflowed to a non-finite value (a pathologically large but
    // finite matrix), fall back to the absolute ε² threshold. Otherwise the
    // `off <= threshold` test could become `∞ <= ∞` and break before any Jacobi
    // rotation, returning the undiagonalized input as its own eigendecomposition.
    let threshold = if norm_sq.is_finite() {
        eps2 * norm_sq
    } else {
        eps2
    };
    for _ in 0..100 {
        // Off-diagonal magnitude (real): Σ_{p<q} |a[p,q]|².
        let mut off = Re::<T>::zero();
        for p in 0..n {
            for q in (p + 1)..n {
                off += a[p * n + q].modulus_squared();
            }
        }
        if off <= threshold {
            break;
        }
        for p in 0..n {
            for q in (p + 1)..n {
                let apq = a[p * n + q];
                let gmod = apq.modulus_squared().sqrt(); // |γ|
                if gmod <= Re::<T>::zero() {
                    continue;
                }
                // Hermitian diagonal is real.
                let app = a[p * n + p].real_part();
                let aqq = a[q * n + q].real_part();
                let zeta = (app - aqq) / (two * gmod);
                let t = if zeta == Re::<T>::zero() {
                    one
                } else {
                    let sgn = if zeta < Re::<T>::zero() { -one } else { one };
                    sgn / (zeta.abs() + (zeta * zeta + one).sqrt())
                };
                let c = one / (t * t + one).sqrt();
                let s = t * c;

                // Rotation U = diag(1, conj(ρ))·[[c,-s],[s,c]] with phase ρ = γ/|γ|; apply Uᴴ A U.
                let rho = apq * T::from_real(one / gmod);
                let ct = T::from_real(c);
                let cs = T::from_real(s);
                let conj_rho = rho.conjugate();
                let srho = conj_rho * cs; // conj(ρ)·s
                let crho = conj_rho * ct; // conj(ρ)·c
                let rs = rho * cs; // ρ·s
                let rc = rho * ct; // ρ·c

                // A ← A·U (columns p, q).
                for i in 0..n {
                    let aip = a[i * n + p];
                    let aiq = a[i * n + q];
                    a[i * n + p] = ct * aip + srho * aiq;
                    a[i * n + q] = crho * aiq - cs * aip;
                }
                // A ← Uᴴ·A (rows p, q).
                for j in 0..n {
                    let apj = a[p * n + j];
                    let aqj = a[q * n + j];
                    a[p * n + j] = ct * apj + rs * aqj;
                    a[q * n + j] = rc * aqj - cs * apj;
                }
                // V ← V·U (accumulate eigenvectors).
                for i in 0..n {
                    let vip = v[i * n + p];
                    let viq = v[i * n + q];
                    v[i * n + p] = ct * vip + srho * viq;
                    v[i * n + q] = crho * viq - cs * vip;
                }
            }
        }
    }
    let evals: Vec<T> = (0..n).map(|i| a[i * n + i]).collect();
    (evals, v)
}

impl<T> CausalTensor<T>
where
    T: ConjugateScalar,
{
    /// Dense eigendecomposition of a **Hermitian** (real: symmetric) `n×n` matrix by cyclic
    /// Jacobi rotations, for real, dual, and complex scalars alike.
    ///
    /// Returns `(eigenvalues, V)` where the eigenvalues are real (carried as `T`, unsorted) and
    /// the columns of the `n×n` tensor `V` are the corresponding orthonormal eigenvectors, so
    /// `A = V · diag(λ) · Vᴴ`.
    ///
    /// The input is **assumed** (numerically) Hermitian: only the strict upper triangle and the
    /// real part of the diagonal are read, so a non-Hermitian input yields an unspecified
    /// decomposition (it is not silently symmetrized). Callers that need the guarantee should
    /// validate `A == Aᴴ` first.
    ///
    /// # Reference
    /// G. H. Golub and C. F. Van Loan, *Matrix Computations*, 4th ed. (Johns Hopkins Univ.
    /// Press, 2013), §8.5 (Jacobi methods).
    ///
    /// # Errors
    /// Returns [`CausalTensorError::DimensionMismatch`] if `self` is not 2-dimensional,
    /// [`CausalTensorError::ShapeMismatch`] if it is not square, or
    /// [`CausalTensorError::EmptyTensor`] if either dimension is zero.
    pub fn eigen_hermitian(&self) -> Result<(Vec<T>, Self), CausalTensorError> {
        if self.shape().len() != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }
        if self.shape()[0] == 0 || self.shape()[1] == 0 {
            return Err(CausalTensorError::EmptyTensor);
        }
        let n = self.shape()[0];
        if n != self.shape()[1] {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let (vals, vecs) = sym_eig(self.as_slice(), n);
        let v = CausalTensor::new(vecs, vec![n, n])?;
        Ok((vals, v))
    }
}
