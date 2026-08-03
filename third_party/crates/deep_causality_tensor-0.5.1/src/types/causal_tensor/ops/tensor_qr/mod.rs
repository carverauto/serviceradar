/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::{ConjugateScalar, Real};
use deep_causality_num::{One, Zero};

/// The real magnitude type of a conjugate scalar.
type Re<T> = <T as ConjugateScalar>::Real;

impl<T> CausalTensor<T>
where
    T: ConjugateScalar,
{
    /// Thin Householder QR: `A = Q · R` with `Q` (`m × k`) orthonormal columns and `R` (`k × n`)
    /// upper-triangular, where `k = min(m, n)`.
    ///
    /// This is the canonicalization primitive for tensor trains (Stage 0): QR — not SVD — is the
    /// standard, cheaper gauge sweep. The reflectors are applied in place to a working copy of `A`
    /// to form `R`, and accumulated into `Q`. For a complex scalar the reflectors are the genuine
    /// Householder reflectors `H = I − β v vᴴ` (conjugated inner products, unitary `Q`); for a real
    /// scalar the conjugation is the identity and it reduces to the ordinary real Householder QR.
    ///
    /// # Reference
    /// G. H. Golub and C. F. Van Loan, *Matrix Computations*, 4th ed. (Johns Hopkins Univ. Press,
    /// 2013), §5.2 (Householder QR factorization).
    ///
    /// # Errors
    /// Returns [`CausalTensorError::DimensionMismatch`] if `self` is not 2-dimensional, or
    /// [`CausalTensorError::EmptyTensor`] if either dimension is zero.
    pub fn qr(&self) -> Result<(Self, Self), CausalTensorError> {
        if self.shape().len() != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }
        let m = self.shape()[0];
        let n = self.shape()[1];
        if m == 0 || n == 0 {
            return Err(CausalTensorError::EmptyTensor);
        }
        let k = m.min(n);

        // Working copy of A (becomes R after the reflectors); Q accumulates as m × m.
        let mut r = self.as_slice().to_vec(); // m × n, row-major
        let mut q = vec![T::zero(); m * m];
        for i in 0..m {
            q[i * m + i] = T::one();
        }

        // Noise floor on a sub-column's squared norm. A column whose norm falls below `‖A‖·ε` is
        // numerically zero; reflecting it makes `vᴴv` a denormal and `β = 2/(vᴴv)` overflow to ∞,
        // which then poisons the factor `β·dot` with NaN. Such a column is already (numerically)
        // upper-triangular, so its reflector is simply skipped (Q's column stays the identity column).
        let eps = Re::<T>::epsilon();
        let mut frob_sq = Re::<T>::zero();
        for x in &r {
            frob_sq += x.modulus_squared();
        }
        let floor = frob_sq * eps * eps;

        for j in 0..k {
            // Norm of the sub-column r[j..m, j] (real).
            let mut norm_sq = Re::<T>::zero();
            for i in j..m {
                norm_sq += r[i * n + j].modulus_squared();
            }
            if norm_sq <= floor {
                continue;
            }
            let norm = norm_sq.sqrt();

            // Pivot phase: alpha = −phase(r[j,j])·‖x‖ avoids cancellation and matches the real
            // ±sign convention (phase = r_jj / |r_jj|, or 1 when the pivot is zero).
            let pivot = r[j * n + j];
            let pmod = pivot.modulus_squared().sqrt();
            let phase = if pmod > Re::<T>::zero() {
                pivot * T::from_real(Re::<T>::one() / pmod)
            } else {
                T::one()
            };
            let alpha = -(phase * T::from_real(norm));

            // Householder vector v = x − alpha·e_j, supported on rows j..m.
            let mut v = vec![T::zero(); m];
            for i in j..m {
                v[i] = r[i * n + j];
            }
            v[j] -= alpha;

            let mut v_norm_sq = Re::<T>::zero();
            for vi in v.iter().skip(j) {
                v_norm_sq += vi.modulus_squared();
            }
            if v_norm_sq <= Re::<T>::zero() {
                continue;
            }
            let beta = (Re::<T>::one() + Re::<T>::one()) / v_norm_sq; // 2 / (vᴴv)

            // Apply H = I − β v vᴴ to the trailing columns of R: R_col -= β·(vᴴ R_col)·v.
            for col in j..n {
                let mut dot = T::zero(); // vᴴ R_col = Σ conj(v_i)·R[i,col]
                for i in j..m {
                    dot += v[i].conjugate() * r[i * n + col];
                }
                let factor = T::from_real(beta) * dot;
                for i in j..m {
                    r[i * n + col] -= factor * v[i];
                }
            }
            // Accumulate Q ← Q · H = Q − β·(Q v)·vᴴ: Q[row,i] -= β·(Q v)_row·conj(v_i).
            for row in 0..m {
                let mut dot = T::zero(); // (Q v)_row = Σ Q[row,l]·v_l
                for i in j..m {
                    dot += q[row * m + i] * v[i];
                }
                let factor = T::from_real(beta) * dot;
                for i in j..m {
                    q[row * m + i] -= factor * v[i].conjugate();
                }
            }
        }

        // Thin Q: first k columns of the m × m accumulator.
        let mut q_thin = vec![T::zero(); m * k];
        for i in 0..m {
            for c in 0..k {
                q_thin[i * k + c] = q[i * m + c];
            }
        }
        // Thin R: first k rows, with the strictly-lower triangle cleaned to exact zero.
        let mut r_thin = vec![T::zero(); k * n];
        for i in 0..k {
            for col in 0..n {
                r_thin[i * n + col] = if col < i { T::zero() } else { r[i * n + col] };
            }
        }

        let q_tensor = CausalTensor::new(q_thin, vec![m, k])?;
        let r_tensor = CausalTensor::new(r_thin, vec![k, n])?;
        Ok((q_tensor, r_tensor))
    }
}
