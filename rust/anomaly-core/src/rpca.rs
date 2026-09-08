// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Robust PCA via Principal Component Pursuit (Netflix RAD / Surus style): decompose a
//! data matrix `M = L + S`, where `L` is **low-rank** (the repeating seasonal/structural
//! pattern) and `S` is **sparse** (the anomalies). Reshaping a single series into a
//! `slots × periods` matrix (e.g. hour-of-day × days) makes the seasonal pattern the
//! low-rank `L` and off-pattern excursions the sparse `S` — the heavyweight, off-hot-path,
//! optional (default-disabled) core layer that also handles correlated multivariate
//! detection (stack hosts as columns). It is NOT an edge primitive (iterative SVD).
//!
//! Solver: the inexact augmented-Lagrange-multiplier (IALM) PCP iteration with a
//! one-sided Jacobi SVD for the singular-value thresholding step. All matrices are
//! row-major `Vec<Vec<f64>>` (rows of length `cols`).

/// Singular value decomposition `A = U·diag(σ)·Vᵀ` via one-sided Jacobi rotations on
/// columns. Returns `(u, sigma, v)` where `u` is `m×n` row-major (orthonormal columns),
/// `sigma` has length `n`, and `v` is `n×n` row-major (orthonormal columns). Robust and
/// accurate for the modest matrices RPCA reshapes to.
// The rotation loops index two disjoint columns (`ucol[p][i]`/`ucol[q][i]`) by a shared
// inner index `i`, including simultaneous disjoint *mutable* access — which a single
// `.iter_mut()` cannot express, so clippy's `needless_range_loop` rewrite is incorrect here.
#[allow(clippy::needless_range_loop)]
pub fn jacobi_svd(a: &[Vec<f64>]) -> (Vec<Vec<f64>>, Vec<f64>, Vec<Vec<f64>>) {
    let m = a.len();
    let n = if m == 0 { 0 } else { a[0].len() };
    // work in columns: ucol[j] is column j (length m); starts as A's columns.
    let mut ucol: Vec<Vec<f64>> = (0..n).map(|j| (0..m).map(|i| a[i][j]).collect()).collect();
    // vcol[j] is column j of V (length n); starts as identity.
    let mut vcol: Vec<Vec<f64>> = (0..n)
        .map(|j| (0..n).map(|i| if i == j { 1.0 } else { 0.0 }).collect())
        .collect();

    for _sweep in 0..80 {
        let mut off = 0.0_f64;
        for p in 0..n {
            for q in (p + 1)..n {
                let mut alpha = 0.0;
                let mut beta = 0.0;
                let mut gamma = 0.0;
                for i in 0..m {
                    alpha += ucol[p][i] * ucol[p][i];
                    beta += ucol[q][i] * ucol[q][i];
                    gamma += ucol[p][i] * ucol[q][i];
                }
                off += gamma * gamma;
                if gamma.abs() <= 1e-15 * (alpha * beta).sqrt() {
                    continue;
                }
                let zeta = (beta - alpha) / (2.0 * gamma);
                let sign = if zeta >= 0.0 { 1.0 } else { -1.0 };
                let t = sign / (zeta.abs() + (1.0 + zeta * zeta).sqrt());
                let c = 1.0 / (1.0 + t * t).sqrt();
                let s = c * t;
                for i in 0..m {
                    let up = ucol[p][i];
                    let uq = ucol[q][i];
                    ucol[p][i] = c * up - s * uq;
                    ucol[q][i] = s * up + c * uq;
                }
                for i in 0..n {
                    let vp = vcol[p][i];
                    let vq = vcol[q][i];
                    vcol[p][i] = c * vp - s * vq;
                    vcol[q][i] = s * vp + c * vq;
                }
            }
        }
        if off.sqrt() < 1e-13 {
            break;
        }
    }

    let mut sigma = vec![0.0; n];
    for j in 0..n {
        let norm = (0..m).map(|i| ucol[j][i] * ucol[j][i]).sum::<f64>().sqrt();
        sigma[j] = norm;
        if norm > 1e-300 {
            for i in 0..m {
                ucol[j][i] /= norm;
            }
        }
    }

    // back to row-major
    let u: Vec<Vec<f64>> = (0..m)
        .map(|i| (0..n).map(|j| ucol[j][i]).collect())
        .collect();
    let v: Vec<Vec<f64>> = (0..n)
        .map(|i| (0..n).map(|j| vcol[j][i]).collect())
        .collect();
    (u, sigma, v)
}

/// Singular-value thresholding `D_τ(A) = U·diag(max(σ-τ,0))·Vᵀ`.
fn svt(a: &[Vec<f64>], tau: f64) -> Vec<Vec<f64>> {
    let m = a.len();
    let n = if m == 0 { 0 } else { a[0].len() };
    let (u, sigma, v) = jacobi_svd(a);
    let st: Vec<f64> = sigma.iter().map(|&s| (s - tau).max(0.0)).collect();
    let mut out = vec![vec![0.0; n]; m];
    for k in 0..n {
        if st[k] <= 0.0 {
            continue;
        }
        for i in 0..m {
            let uik = u[i][k] * st[k];
            if uik == 0.0 {
                continue;
            }
            for j in 0..n {
                out[i][j] += uik * v[j][k];
            }
        }
    }
    out
}

/// Robust PCA via inexact-ALM PCP. Returns `(l, s)` (low-rank, sparse) with `l + s ≈ a`.
/// `lambda` defaults to `1/sqrt(max(rows, cols))` (the PCP theory value).
pub fn rpca(
    a: &[Vec<f64>],
    lambda: Option<f64>,
    max_iter: usize,
    tol: f64,
) -> (Vec<Vec<f64>>, Vec<Vec<f64>>) {
    let m = a.len();
    let n = if m == 0 { 0 } else { a[0].len() };
    if m == 0 || n == 0 {
        return (vec![], vec![]);
    }
    let lam = lambda.unwrap_or(1.0 / (m.max(n) as f64).sqrt());

    let fro = |x: &[Vec<f64>]| -> f64 {
        x.iter()
            .flat_map(|r| r.iter())
            .map(|v| v * v)
            .sum::<f64>()
            .sqrt()
    };
    let m_fro = fro(a).max(1e-12);
    let l1: f64 = a.iter().flat_map(|r| r.iter()).map(|v| v.abs()).sum();
    let mut mu = (m * n) as f64 / (4.0 * l1.max(1e-12));
    let mu_max = mu * 1e7;
    let rho = 1.5;

    let mut l = vec![vec![0.0; n]; m];
    let mut s = vec![vec![0.0; n]; m];
    let mut y = vec![vec![0.0; n]; m];

    for _ in 0..max_iter {
        // L = D_{1/mu}(A - S + Y/mu)
        let tmp: Vec<Vec<f64>> = (0..m)
            .map(|i| (0..n).map(|j| a[i][j] - s[i][j] + y[i][j] / mu).collect())
            .collect();
        l = svt(&tmp, 1.0 / mu);
        // S = soft_{lambda/mu}(A - L + Y/mu)
        let th = lam / mu;
        for i in 0..m {
            for j in 0..n {
                let val = a[i][j] - l[i][j] + y[i][j] / mu;
                s[i][j] = val.signum() * (val.abs() - th).max(0.0);
            }
        }
        // Y += mu (A - L - S); check convergence
        let mut resid = 0.0;
        for i in 0..m {
            for j in 0..n {
                let r = a[i][j] - l[i][j] - s[i][j];
                y[i][j] += mu * r;
                resid += r * r;
            }
        }
        if resid.sqrt() / m_fro < tol {
            break;
        }
        mu = (mu * rho).min(mu_max);
    }
    (l, s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matmul_check(a: &[Vec<f64>]) -> f64 {
        // ||A - U diag(sigma) V^T||_F
        let m = a.len();
        let n = a[0].len();
        let (u, sigma, v) = jacobi_svd(a);
        let mut err = 0.0;
        for i in 0..m {
            for j in 0..n {
                let mut recon = 0.0;
                for k in 0..n {
                    recon += u[i][k] * sigma[k] * v[j][k];
                }
                err += (a[i][j] - recon).powi(2);
            }
        }
        err.sqrt()
    }

    #[test]
    fn svd_reconstructs_and_is_orthonormal() {
        let a = vec![
            vec![4.0, 0.0, 1.0],
            vec![0.0, 3.0, -1.0],
            vec![2.0, 1.0, 5.0],
            vec![1.0, -2.0, 0.5],
        ];
        assert!(matmul_check(&a) < 1e-8, "A must reconstruct from its SVD");
        // U columns orthonormal
        let (u, _s, v) = jacobi_svd(&a);
        let n = 3;
        for p in 0..n {
            for q in 0..n {
                let dot: f64 = (0..u.len()).map(|i| u[i][p] * u[i][q]).sum();
                let want = if p == q { 1.0 } else { 0.0 };
                assert!(
                    (dot - want).abs() < 1e-7,
                    "U cols not orthonormal: {p},{q}={dot}"
                );
                let dotv: f64 = (0..n).map(|i| v[i][p] * v[i][q]).sum();
                assert!((dotv - want).abs() < 1e-7, "V cols not orthonormal");
            }
        }
    }

    #[test]
    fn rpca_separates_low_rank_from_sparse_spikes() {
        // L_true: rank-1 (every row = the same seasonal profile scaled per row).
        let profile = [10.0, 12.0, 9.0, 11.0, 8.0, 13.0];
        let scales = [1.0, 1.1, 0.9, 1.05, 0.95, 1.2, 1.0, 0.85];
        let m = scales.len();
        let n = profile.len();
        let mut a: Vec<Vec<f64>> = (0..m)
            .map(|i| (0..n).map(|j| scales[i] * profile[j]).collect())
            .collect();
        // inject two sparse spikes
        a[2][4] += 30.0; // (2,4)
        a[6][1] += 25.0; // (6,1)

        let (l, s) = rpca(&a, None, 500, 1e-7);

        // reconstruction
        let mut rerr = 0.0;
        for i in 0..m {
            for j in 0..n {
                rerr += (a[i][j] - l[i][j] - s[i][j]).powi(2);
            }
        }
        assert!(
            rerr.sqrt() < 1e-3,
            "L + S must reconstruct A, err={}",
            rerr.sqrt()
        );

        // the sparse component recovers the spike locations as its largest entries
        let mut entries: Vec<(f64, usize, usize)> = Vec::new();
        for (i, row) in s.iter().enumerate() {
            for (j, val) in row.iter().enumerate() {
                entries.push((val.abs(), i, j));
            }
        }
        entries.sort_by(|x, y| y.0.partial_cmp(&x.0).unwrap());
        let top: Vec<(usize, usize)> = entries.iter().take(2).map(|e| (e.1, e.2)).collect();
        assert!(
            top.contains(&(2, 4)),
            "S should flag spike (2,4), got {top:?}"
        );
        assert!(
            top.contains(&(6, 1)),
            "S should flag spike (6,1), got {top:?}"
        );
        // and the spike magnitudes are recovered to a sensible degree
        assert!(s[2][4].abs() > 15.0 && s[6][1].abs() > 12.0);
    }
}
