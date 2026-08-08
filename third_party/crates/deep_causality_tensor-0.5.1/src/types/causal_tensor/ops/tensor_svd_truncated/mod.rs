/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::causal_tensor_network::causal_tensor_train::linalg::matmul;
use crate::types::causal_tensor_network::rng::gaussian_vec;
use crate::types::causal_tensor_network::truncation::{RoundStrategy, Truncation};
use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::{ConjugateScalar, Real};
use deep_causality_num::{One, Zero};

/// The real magnitude type of a conjugate scalar (`Self` for reals, the underlying real for complex).
type Re<T> = <T as ConjugateScalar>::Real;

impl<T> CausalTensor<T>
where
    T: ConjugateScalar,
{
    /// Robust truncated thin-SVD: `A ≈ U · diag(S) · Vᴴ`, retaining only the rank selected by
    /// `trunc`.
    ///
    /// This is the tensor-network numerical foundation (Stage 0). The decomposition is computed by
    /// **one-sided Jacobi rotations**, chosen over implicit-shift Golub–Kahan because it delivers
    /// orthonormal factors to high relative accuracy with a simple, branch-stable kernel — the
    /// property TT-SVD and rounding compound over many sweeps.
    ///
    /// For an `m × n` input it returns `(U, S, Vt)` where `U` is `m × k` with orthonormal columns,
    /// `S` is the length-`k` vector of **real** singular values (in `T::Real`) in non-increasing
    /// order, and `Vt` is `k × n` — the conjugate transpose `Vᴴ` of the right singular vectors —
    /// with `k` the retained rank under `trunc`. For a complex scalar this is the genuine Hermitian
    /// SVD (conjugated inner products, real singular values, unitary `U`/`V`); for a real scalar the
    /// conjugation is the identity and it reduces to the ordinary real SVD.
    ///
    /// # Reference
    /// J. Demmel and K. Veselić, "Jacobi's method is more accurate than QR," *SIAM J. Matrix Anal.
    /// Appl.* 13(4), 1204–1245 (1992). <https://doi.org/10.1137/0613074> — establishes the high
    /// relative accuracy of the one-sided Jacobi SVD used here.
    ///
    /// # Errors
    /// Returns [`CausalTensorError::DimensionMismatch`] if `self` is not 2-dimensional, or
    /// [`CausalTensorError::EmptyTensor`] if either dimension is zero.
    pub fn svd_truncated(
        &self,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<(Self, CausalTensor<<T as ConjugateScalar>::Real>, Self), CausalTensorError> {
        if self.shape().len() != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }
        if self.shape()[0] == 0 || self.shape()[1] == 0 {
            return Err(CausalTensorError::EmptyTensor);
        }
        match trunc.strategy() {
            RoundStrategy::Deterministic => self.svd_jacobi(trunc),
            RoundStrategy::Randomized { oversample, seed } => {
                self.svd_randomized(trunc, oversample, seed)
            }
        }
    }

    /// Deterministic one-sided Jacobi truncated SVD — the default kernel behind
    /// [`CausalTensor::svd_truncated`]. See that method for the contract.
    fn svd_jacobi(
        &self,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<(Self, CausalTensor<<T as ConjugateScalar>::Real>, Self), CausalTensorError> {
        let m = self.shape()[0];
        let n = self.shape()[1];

        // One-sided Jacobi requires rows ≥ cols. When the input is wide, decompose its conjugate
        // transpose and swap the roles of U and V on the way out.
        let transposed = m < n;
        let (rows, cols, work) = if transposed {
            (n, m, conj_transpose(self.as_slice(), m, n))
        } else {
            (m, n, self.as_slice().to_vec())
        };

        // jacobi returns: left factor (rows × cols, orthonormal columns), the singular values
        // (length cols, unsorted, real), and the right factor V (cols × cols, unitary).
        let (u_full, sigma, v_full) = jacobi_svd::<T>(work, rows, cols);

        // Sort singular triplets by magnitude, descending.
        let mut order: Vec<usize> = (0..cols).collect();
        order.sort_by(|&a, &b| {
            sigma[b]
                .partial_cmp(&sigma[a])
                .unwrap_or(core::cmp::Ordering::Equal)
        });
        let sorted: Vec<<T as ConjugateScalar>::Real> = order.iter().map(|&j| sigma[j]).collect();

        let k = trunc.retained_rank(&sorted);

        // Assemble the retained factors in the *original* orientation.
        // Non-transposed: U = u_full (m×k), V = v_full (n×k), Vt = Vᴴ.
        // Transposed:     for Aᴴ = U' S V'ᴴ we have A = V' S U'ᴴ ⇒ U = V', Vt = U'ᴴ.
        let (left, right, left_rows, right_rows) = if transposed {
            (&v_full, &u_full, cols, rows)
        } else {
            (&u_full, &v_full, rows, cols)
        };

        // U is left_rows × k, taking the selected columns.
        let mut u_data = vec![T::zero(); left_rows * k];
        for (col, &j) in order.iter().take(k).enumerate() {
            for row in 0..left_rows {
                u_data[row * k + col] = left[row * cols + j];
            }
        }
        // Vt is k × right_rows; row r is the conjugate of the r-th right singular vector (Vᴴ).
        let mut vt_data = vec![T::zero(); k * right_rows];
        for (r, &j) in order.iter().take(k).enumerate() {
            for c in 0..right_rows {
                vt_data[r * right_rows + c] = right[c * cols + j].conjugate();
            }
        }
        let s_data: Vec<<T as ConjugateScalar>::Real> = sorted.into_iter().take(k).collect();

        let u = CausalTensor::new(u_data, vec![left_rows, k])?;
        let s = CausalTensor::new(s_data, vec![k])?;
        let vt = CausalTensor::new(vt_data, vec![k, right_rows])?;
        Ok((u, s, vt))
    }

    /// Adaptive randomized range-finder truncated SVD — the opt-in kernel behind
    /// [`CausalTensor::svd_truncated`] when [`RoundStrategy::Randomized`] is selected.
    ///
    /// Sketches the column space of `A` with a Gaussian matrix `Ω`, orthonormalizes `Y = A·Ω` by QR
    /// to a basis `Q`, projects `B = Qᴴ·A`, takes the (small) deterministic SVD of `B`, and lifts the
    /// left factors back through `Q` (`U = Q·U_B`). The sketch size `ℓ` grows adaptively until the
    /// captured residual `‖A − Q·Qᴴ·A‖_F` meets the policy tolerance, or the full rank is reached.
    /// Cost is `O(rows·cols·ℓ)` — cheaper than the full Jacobi SVD whenever the retained rank
    /// `ℓ ≪ min(rows, cols)`, which is exactly the low-rank regime of TT rounding.
    ///
    /// # Reference
    /// N. Halko, P. G. Martinsson, J. A. Tropp, "Finding Structure with Randomness," *SIAM Review*
    /// 53(2), 217–288 (2011) — the randomized range-finder; H. Al Daas et al., "Randomized algorithms
    /// for rounding in the tensor-train format," *SIAM J. Sci. Comput.* (2023) — its use in TT rounding.
    fn svd_randomized(
        &self,
        trunc: &Truncation<Re<T>>,
        oversample: usize,
        seed: u64,
    ) -> Result<(Self, CausalTensor<Re<T>>, Self), CausalTensorError> {
        let rows = self.shape()[0];
        let cols = self.shape()[1];
        let a = self.as_slice();
        let maxr = rows.min(cols);

        // A real bond cap fixes the target rank; otherwise the rank is tolerance-driven and the
        // sketch grows adaptively from a modest start.
        let bond_capped = trunc.max_bond() < maxr;
        let mut ell = if bond_capped {
            trunc.max_bond().saturating_add(oversample).min(maxr).max(1)
        } else {
            oversample.max(1).saturating_mul(2).min(maxr).max(1)
        };

        // ‖A‖_F for the relative residual test.
        let mut norm_a_sq = Re::<T>::zero();
        for &x in a {
            norm_a_sq += x.modulus_squared();
        }
        let norm_a = norm_a_sq.sqrt();

        // Range-finding loop: grow ℓ until the projection residual meets the tolerance.
        let (q, qd, b) = loop {
            let omega = gaussian_vec::<T>(
                cols * ell,
                seed ^ (ell as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15),
            );
            let y = matmul(a, rows, cols, &omega, ell); // rows × ell
            let yt = CausalTensor::new(y, vec![rows, ell])?;
            let (q, _r) = yt.qr()?;
            let qd = q.shape()[1]; // ≤ ell
            let qh = conj_transpose(q.as_slice(), rows, qd);
            let b = matmul(&qh, qd, rows, a, cols); // qd × cols

            if ell < maxr {
                // Residual ‖A − Q·B‖_F: Q·B is the rank-ℓ projection of A onto the sketch range.
                let qb = matmul(q.as_slice(), rows, qd, &b, cols);
                let mut res_sq = Re::<T>::zero();
                for (av, qbv) in a.iter().zip(qb.iter()) {
                    res_sq += (*av - *qbv).modulus_squared();
                }
                let res = res_sq.sqrt();
                let rel = trunc.rel_tol() * norm_a;
                let threshold = if rel > trunc.abs_tol() {
                    rel
                } else {
                    trunc.abs_tol()
                };
                if res > threshold {
                    ell = ell.saturating_mul(2).min(maxr);
                    continue;
                }
            }
            break (q, qd, b);
        };

        // Deterministic truncated SVD of the small qd × cols matrix B, then lift U back through Q.
        let bt = CausalTensor::new(b, vec![qd, cols])?;
        let (ub, s, vt) = bt.svd_jacobi(trunc)?; // ub: qd×k, s: k, vt: k×cols
        let k = s.len();
        let u = matmul(q.as_slice(), rows, qd, ub.as_slice(), k); // rows × k
        let u = CausalTensor::new(u, vec![rows, k])?;
        Ok((u, s, vt))
    }
}

/// Conjugate-transposes a row-major `rows × cols` buffer into `cols × rows` (plain transpose for a
/// real scalar, Hermitian transpose for complex).
fn conj_transpose<T: ConjugateScalar>(data: &[T], rows: usize, cols: usize) -> Vec<T> {
    let mut out = vec![T::zero(); rows * cols];
    for i in 0..rows {
        for j in 0..cols {
            out[j * rows + i] = data[i * cols + j].conjugate();
        }
    }
    out
}

/// One-sided Jacobi SVD of a tall-or-square matrix (`rows ≥ cols`), conjugate-aware.
///
/// Returns `(u, sigma, v)` where `u` is `rows × cols` with orthonormal columns (for nonzero
/// singular values), `sigma` is the length-`cols` vector of **real** singular values (unsorted), and
/// `v` is the `cols × cols` unitary matrix of right singular vectors. Columns are orthogonalized
/// under the Hermitian inner product `⟨x|y⟩ = Σ x̄ᵢ yᵢ`; each `2×2` sub-problem is reduced to a real
/// Jacobi rotation by factoring the complex off-diagonal into modulus and phase.
fn jacobi_svd<T>(
    mut u: Vec<T>,
    rows: usize,
    cols: usize,
) -> (Vec<T>, Vec<<T as ConjugateScalar>::Real>, Vec<T>)
where
    T: ConjugateScalar,
{
    let two = Re::<T>::one() + Re::<T>::one();
    // Convergence threshold: a small multiple of the working epsilon, so it scales with precision.
    let mut tol = Re::<T>::epsilon();
    for _ in 0..6 {
        tol = tol + tol; // epsilon · 64
    }
    let max_sweeps = 60usize;

    // v starts as the identity (cols × cols).
    let mut v = vec![T::zero(); cols * cols];
    for i in 0..cols {
        v[i * cols + i] = T::one();
    }

    // Noise floor on a column's squared norm: a column whose norm falls below `‖A‖·ε` is numerically
    // zero. Rank-deficient matrices drive surplus columns toward zero, and rotating a near-zero column
    // yields pathological angles (`gmod → 0 ⇒ ζ → ∞`) that overflow/NaN the rotation. Skipping such
    // columns leaves their singular value ~0 (dropped downstream by `retained_rank`).
    let eps = Re::<T>::epsilon();
    let mut max_diag = Re::<T>::zero();
    for j in 0..cols {
        let mut nrm = Re::<T>::zero();
        for i in 0..rows {
            nrm += u[i * cols + j].modulus_squared();
        }
        if nrm > max_diag {
            max_diag = nrm;
        }
    }
    let floor = max_diag * eps * eps;

    for _sweep in 0..max_sweeps {
        let mut max_off = Re::<T>::zero();
        for p in 0..cols {
            for q in (p + 1)..cols {
                // Hermitian Gram entries of columns p and q.
                let mut alpha = Re::<T>::zero(); // ⟨x_p|x_p⟩ (real)
                let mut beta = Re::<T>::zero(); // ⟨x_q|x_q⟩ (real)
                let mut gamma = T::zero(); // ⟨x_p|x_q⟩ (complex)
                for i in 0..rows {
                    let uip = u[i * cols + p];
                    let uiq = u[i * cols + q];
                    alpha += uip.modulus_squared();
                    beta += uiq.modulus_squared();
                    gamma += uip.conjugate() * uiq;
                }
                // Either column numerically zero ⇒ nothing to orthogonalize; skip (avoids the
                // near-zero-column rotation pathology).
                if alpha <= floor || beta <= floor {
                    continue;
                }
                let gmod = gamma.modulus_squared().sqrt(); // |γ| (real)
                let denom = (alpha * beta).sqrt();
                if denom > Re::<T>::zero() {
                    let rel = gmod / denom;
                    if rel > max_off {
                        max_off = rel;
                    }
                    // Already orthogonal to working precision: skip the rotation.
                    if rel <= tol {
                        continue;
                    }
                } else {
                    // A degenerate (zero-norm) column pair contributes nothing to rotate.
                    continue;
                }

                // Real Jacobi angle from (alpha, beta, |γ|); the complex phase is split off into `e`.
                let zeta = (beta - alpha) / (two * gmod);
                let sign = if zeta < Re::<T>::zero() {
                    -Re::<T>::one()
                } else {
                    Re::<T>::one()
                };
                // `sqrt(1 + ζ²)` computed without overflow: when `|ζ|` is large (a near-zero column
                // drives `gmod → 0`, so `ζ → ∞`), `ζ²` would overflow and `sqrt(∞)` is NaN on a
                // double-double scalar — poisoning the rotation. Factor out `|ζ|` instead, so the term
                // is `|ζ|·sqrt(1 + 1/ζ²)` with `1/ζ²` harmlessly underflowing to zero.
                let az = zeta.abs();
                let root = if az > Re::<T>::one() {
                    let inv = Re::<T>::one() / az;
                    az * (Re::<T>::one() + inv * inv).sqrt()
                } else {
                    (Re::<T>::one() + zeta * zeta).sqrt()
                };
                let t = sign / (az + root);
                let c = Re::<T>::one() / (Re::<T>::one() + t * t).sqrt();
                let s = c * t;

                // Complex Givens rotation with phase ρ = γ/|γ| (unit modulus):
                //   x'_p = c·x_p − conj(ρ)·s·x_q,   x'_q = ρ·s·x_p + c·x_q.
                // For a real scalar ρ = ±1 and this reduces to the ordinary real Jacobi rotation.
                let rho = gamma * T::from_real(Re::<T>::one() / gmod);
                let ct = T::from_real(c);
                let es = rho * T::from_real(s); // ρ·s
                let conj_es = rho.conjugate() * T::from_real(s); // conj(ρ)·s

                for i in 0..rows {
                    let uip = u[i * cols + p];
                    let uiq = u[i * cols + q];
                    u[i * cols + p] = ct * uip - conj_es * uiq;
                    u[i * cols + q] = es * uip + ct * uiq;
                }
                for i in 0..cols {
                    let vip = v[i * cols + p];
                    let viq = v[i * cols + q];
                    v[i * cols + p] = ct * vip - conj_es * viq;
                    v[i * cols + q] = es * vip + ct * viq;
                }
            }
        }
        if max_off <= tol {
            break;
        }
    }

    // Singular values are the column norms; normalize the columns of u into the left factor.
    let mut sigma = vec![Re::<T>::zero(); cols];
    for j in 0..cols {
        let mut norm_sq = Re::<T>::zero();
        for i in 0..rows {
            norm_sq += u[i * cols + j].modulus_squared();
        }
        let norm = norm_sq.sqrt();
        sigma[j] = norm;
        if norm > Re::<T>::zero() {
            let inv_norm = T::from_real(Re::<T>::one() / norm);
            for i in 0..rows {
                u[i * cols + j] *= inv_norm;
            }
        }
    }

    (u, sigma, v)
}
