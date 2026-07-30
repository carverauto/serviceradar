/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Randomize-then-orthogonalize tensor-train rounding (Al Daas–Ballard, *SIAM J. Sci. Comput.* 2023).
//!
//! The deterministic `round` left-canonicalizes the *full* train (a QR sweep over the high-bond cores)
//! and only then truncates — and that canonicalization, not the SVD, dominates at large bond. This
//! scheme avoids it: it first **sketches** the train against random Gaussian matrices via a structured
//! (Khatri-Rao) right-to-left contraction, then orthogonalizes only the *small* sketched basis
//! (`ℓ` columns) left-to-right. No QR ever touches a full bond-`r` unfolding, so the cost is
//! `O(d·n·r²·ℓ)` with `ℓ ≈ target rank + oversample`.

use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::causal_tensor_train::linalg::matmul;
use crate::types::causal_tensor_network::rng::gaussian_vec;
use crate::types::causal_tensor_network::truncation::Truncation;
use crate::{CausalTensor, CausalTensorError, Tensor, TensorTrain};
use deep_causality_algebra::ConjugateScalar;

type Re<T> = <T as ConjugateScalar>::Real;

/// Conjugate transpose of a row-major `rows × cols` buffer into `cols × rows`.
fn conj_transpose<T: ConjugateScalar>(a: &[T], rows: usize, cols: usize) -> Vec<T> {
    let mut out = vec![T::zero(); rows * cols];
    for i in 0..rows {
        for j in 0..cols {
            out[j * rows + i] = a[i * cols + j].conjugate();
        }
    }
    out
}

impl<T> CausalTensorTrain<T>
where
    T: ConjugateScalar,
{
    /// Rounds via randomize-then-orthogonalize, growing the sketch size until it captures the rank the
    /// tolerance requires, then trimming with one cheap deterministic round of the *small* sketched
    /// train. Falls back to the deterministic round for order ≤ 1 or a degenerate sketch.
    pub(crate) fn round_randomized(
        &self,
        trunc: &Truncation<Re<T>>,
        oversample: usize,
        seed: u64,
    ) -> Result<Self, CausalTensorError> {
        let d = self.order();
        // The deterministic trim policy (same gates, deterministic kernel).
        let det = Truncation::new(trunc.max_bond(), trunc.rel_tol(), trunc.abs_tol())?;
        if d <= 1 {
            return self.round(&det);
        }

        let max_in = self.cores().iter().map(|c| c.shape()[2]).max().unwrap_or(1);
        let bond_capped = trunc.max_bond() < max_in;
        let os = oversample.max(1);
        let mut ell = if bond_capped {
            trunc.max_bond().saturating_add(os)
        } else {
            os.saturating_mul(2)
        }
        .clamp(1, max_in);

        loop {
            let sketched =
                self.sketch_orthogonalize(ell, seed ^ (ell as u64).wrapping_mul(0x9E37))?;
            let rounded = sketched.round(&det)?;
            let got = rounded
                .cores()
                .iter()
                .map(|c| c.shape()[2])
                .max()
                .unwrap_or(1);
            // Slack remaining (got < ell) means the sketch captured the full rank; otherwise grow.
            if bond_capped || got < ell || ell >= max_in {
                return Ok(rounded);
            }
            ell = ell.saturating_mul(2).min(max_in);
        }
    }

    /// One randomize-then-orthogonalize pass at sketch size `ell`, returning a left-orthogonal train
    /// whose interior bonds are at most `ell`.
    fn sketch_orthogonalize(&self, ell: usize, seed: u64) -> Result<Self, CausalTensorError> {
        let cores = self.cores();
        let d = cores.len();
        let dims: Vec<(usize, usize, usize)> = cores
            .iter()
            .map(|c| (c.shape()[0], c.shape()[1], c.shape()[2]))
            .collect();

        // Per-mode Gaussian sketches Ω_j (n_j × ell), seeded independently.
        let omega: Vec<Vec<T>> = (0..d)
            .map(|j| {
                gaussian_vec::<T>(dims[j].1 * ell, seed ^ (j as u64).wrapping_mul(0x1000_0001))
            })
            .collect();

        // Phase 1 — right-to-left structured sketch. p[j] (j = 1..=d-1) is [r_left(j), ell], the
        // sketch of cores j..d-1. p[d-1] = H(core_{d-1})·Ω_{d-1}; then fold in via Khatri-Rao.
        let mut p: Vec<Vec<T>> = vec![Vec::new(); d];
        {
            let (rl, n, rr) = dims[d - 1]; // rr == 1
            // H(core) = [rl, n*rr]; Ω is [n, ell]; with rr==1, n*rr == n.
            p[d - 1] = matmul(cores[d - 1].as_slice(), rl, n * rr, &omega[d - 1], ell);
            debug_assert_eq!(rr, 1);
        }
        for j in (1..d - 1).rev() {
            let (rl, n, rr) = dims[j];
            // Khatri-Rao (p[j+1] ⊙ Ω_j): row (i*rr + b), col c → Ω_j[i,c] · p[j+1][b,c].
            let mut krp = vec![T::zero(); n * rr * ell];
            let pj1 = &p[j + 1]; // [rr, ell]
            let om = &omega[j]; // [n, ell]
            for i in 0..n {
                for b in 0..rr {
                    let row = i * rr + b;
                    for c in 0..ell {
                        krp[row * ell + c] = om[i * ell + c] * pj1[b * ell + c];
                    }
                }
            }
            // H(core_j) = [rl, n*rr]; p[j] = H·krp = [rl, ell].
            p[j] = matmul(cores[j].as_slice(), rl, n * rr, &krp, ell);
        }

        // Phase 2 — left-to-right orthogonalization of the sketched basis only.
        let mut ycores: Vec<CausalTensor<T>> = Vec::with_capacity(d);
        let mut cur = cores[0].as_slice().to_vec(); // [1, n_0, rr_0]
        let mut rly = 1usize; // current left bond of Y
        for k in 0..d - 1 {
            let (_, n, rr) = dims[k];
            // V(cur) = [rly*n, rr]; S = V(cur)·p[k+1] = [rly*n, ell].
            let s = matmul(&cur, rly * n, rr, &p[k + 1], ell);
            let st = CausalTensor::new(s, vec![rly * n, ell])?;
            let (q, _r) = st.qr()?;
            let qd = q.shape()[1]; // ≤ ell
            ycores.push(q.reshape(&[rly, n, qd])?);
            // M = Qᴴ·V(cur) = [qd, rr]; push into the next core: cur = M·H(core_{k+1}).
            let qh = conj_transpose(q.as_slice(), rly * n, qd);
            let m = matmul(&qh, qd, rly * n, &cur, rr); // [qd, rr]
            let (_, n1, rr1) = dims[k + 1];
            cur = matmul(&m, qd, rr, cores[k + 1].as_slice(), n1 * rr1); // [qd, n1*rr1]
            rly = qd;
        }
        // Last core: cur is [rly, n_{d-1}, 1].
        let (_, nl, _) = dims[d - 1];
        ycores.push(CausalTensor::new(cur, vec![rly, nl, 1])?);

        Self::from_cores(ycores)
    }
}
