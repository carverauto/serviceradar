/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::TensorTrain;
use crate::traits::tensor_train_operator::TensorTrainOperator;
use crate::types::causal_tensor::sym_eig;
use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::causal_tensor_train_operator::CausalTensorTrainOperator;
use crate::types::causal_tensor_network::solve_config::SolveConfig;
use crate::types::causal_tensor_network::truncation::Truncation;
use crate::{CausalTensor, CausalTensorError, Tensor};
use deep_causality_algebra::{ConjugateScalar, Real};
use deep_causality_num::{One, Zero};

/// The real magnitude type of a conjugate scalar.
type Re<T> = <T as ConjugateScalar>::Real;

/// Fits a tensor train of bond dimension up to `max_rank` to a set of `(index, value)` samples by
/// alternating least squares (TT completion / regression).
///
/// At each site the local objective is least-squares in that core and **block-diagonal over the
/// physical index** (a sample only touches its own physical slice), so each slice is a small
/// `(r_k·r_{k+1})` ridge-regularized normal-equation solve.
///
/// # References
/// - S. Holtz, T. Rohwedder, and R. Schneider, "The alternating linear scheme for tensor
///   optimization in the tensor train format," *SIAM J. Sci. Comput.* 34(2), A683–A713 (2012).
///   <https://doi.org/10.1137/100818893> — the one-site ALS optimization scheme.
/// - L. Grasedyck, M. Kluge, and S. Krämer, "Variants of alternating least squares tensor
///   completion in the tensor train format," *SIAM J. Sci. Comput.* 37(5), A2424–A2450 (2015).
///   <https://doi.org/10.1137/130942401> — ALS specialized to completion from samples.
///
/// # Errors
/// - [`CausalTensorError::EmptyTensor`] if `shape` is empty / has a zero dimension or there are no
///   samples.
/// - [`CausalTensorError::SweepDidNotConverge`] if the RMS residual stays above `tol` after
///   `max_sweeps`.
pub fn fit<T: ConjugateScalar>(
    shape: &[usize],
    max_rank: usize,
    samples: &[(Vec<usize>, T)],
    config: &SolveConfig<<T as ConjugateScalar>::Real>,
) -> Result<CausalTensorTrain<T>, CausalTensorError> {
    let d = shape.len();
    if d == 0 || shape.contains(&0) || samples.is_empty() {
        return Err(CausalTensorError::EmptyTensor);
    }
    let ranks = bond_ranks(shape, max_rank);
    let mut cores = init_random(shape, &ranks, 0xF17_F17);

    let mut residual = rms_residual(&cores, samples)?;
    for _sweep in 0..config.max_sweeps() {
        // Forward then backward over the sites (Gauss–Seidel coordinate descent).
        for k in forward_then_back(d) {
            fit_site(&mut cores, shape, k, samples, config.ridge());
        }
        residual = rms_residual(&cores, samples)?;
        if residual <= config.tol() {
            return CausalTensorTrain::from_cores(cores);
        }
    }
    let _ = residual;
    Err(CausalTensorError::SweepDidNotConverge)
}

/// Solves `A x = b` for `x` in tensor-train form by the **AMEn** (Alternating Minimal Energy)
/// algorithm: one-site ALS optimization with **residual subspace enrichment**, which makes the
/// bond dimension *rank-adaptive* — `x` is seeded at a small rank and grown toward the residual each
/// sweep (capped at `max_rank`), so the caller does not have to guess the right rank.
///
/// When `A` is **square** (`in_dims == out_dims`) the local Galerkin systems use `A` and `b`
/// directly, so the conditioning is `cond(A)`. For a rectangular `A` it falls back to the symmetric
/// positive-definite normal equations `G x = c` with `G = Aᵀ∘A`, `c = Aᵀ·b` (conditioning
/// `cond(A)²`) — the original AMEn-Part-I setting.
///
/// Reference: S. V. Dolgov and D. V. Savostyanov, "Alternating minimal energy methods for linear
/// systems in higher dimensions," *SIAM J. Sci. Comput.* 36(5), A2248–A2271 (2014).
/// <https://doi.org/10.1137/140953289> (arXiv:1301.6068).
///
/// # Errors
/// - [`CausalTensorError::ShapeMismatch`] if `b`'s physical dimensions differ from `A`'s output.
/// - [`CausalTensorError::SweepDidNotConverge`] if the relative residual stays above `tol`.
pub fn linear<T: ConjugateScalar>(
    a: &CausalTensorTrainOperator<T>,
    b: &CausalTensorTrain<T>,
    max_rank: usize,
    config: &SolveConfig<<T as ConjugateScalar>::Real>,
) -> Result<CausalTensorTrain<T>, CausalTensorError> {
    if b.phys_dims() != a.out_dims() {
        return Err(CausalTensorError::ShapeMismatch);
    }
    let exact = Truncation::by_bond(usize::MAX)?;

    // Square operator: solve A x = b directly (cond A). Otherwise normal equations (cond A²).
    let (op, rhs) = if a.in_dims() == a.out_dims() {
        (a.clone(), b.clone())
    } else {
        let at = a.transpose();
        (at.compose(a, &exact)?, at.apply(b, &exact)?)
    };

    let shape = a.in_dims().to_vec();
    let d = shape.len();
    let caps = bond_ranks(&shape, max_rank);
    // Seed at a small rank; AMEn enrichment grows it toward the residual.
    let seed: Vec<usize> = caps.iter().map(|&r| r.min(2)).collect();
    let mut x = init_random(&shape, &seed, 0x5017_5017);

    // Enrichment rounding: cap at max_rank and drop directions below the tolerance (rank-adaptive).
    let enrich_trunc = Truncation::new(max_rank, config.tol(), Re::<T>::zero())?;
    let rhs_norm = rhs.norm()?.real_part();

    for _sweep in 0..config.max_sweeps() {
        // ALS optimization of the cores at the current rank.
        for k in forward_then_back(d) {
            linear_site(&mut x, &op, &rhs, k, config.ridge())?;
        }
        // Residual r = rhs − op·x; its relative magnitude is real.
        let xt = CausalTensorTrain::from_cores_raw(x.clone(), CanonicalForm::None);
        let ox = op.apply(&xt, &exact)?;
        let res = rhs.add(&ox.scale(-T::one()))?;
        let rnorm = res.norm()?.real_part() / (rhs_norm + Re::<T>::epsilon());
        if rnorm <= config.tol() {
            return CausalTensorTrain::from_cores(x);
        }
        // AMEn enrichment: augment the basis with the residual direction, capped at max_rank.
        x = xt.add(&res)?.round(&enrich_trunc)?.into_cores();
    }
    Err(CausalTensorError::SweepDidNotConverge)
}

/// Computes the lowest eigenpair `(λ, v)` of a **Hermitian** tensor-train operator `A` by the
/// **DMRG3S** algorithm: a single-site DMRG sweep (each site solves the local single-site eigenproblem
/// for the smallest Rayleigh quotient) combined with **subspace expansion** — the bond dimension is
/// grown rank-adaptively by enriching `v` with the projected residual `A·v − λ·v` (the same
/// residual-enrichment engine used by [`linear`]), seeded small and capped at `max_rank`.
///
/// Each site is solved in **mixed-canonical gauge**: the state is `canonicalize_at(k)`-ed before the
/// local solve so the environment is orthonormal and the single-site problem is a *standard* Hermitian
/// eigenproblem `H z = λ z` (solved by the cyclic-Jacobi `sym_eig`, which uses complex Givens
/// similarity for complex scalars and reduces to the real symmetric Jacobi for real ones).
///
/// `A` must be (numerically) Hermitian — the effective operator is Hermitian-symmetrized before each
/// local solve. The returned `λ` is real (returned as `T`) and the smallest (most negative) eigenvalue.
///
/// Reference: C. Hubig, I. P. McCulloch, U. Schollwöck, and F. A. Wolf, "Strictly single-site DMRG
/// algorithm with subspace expansion," *Phys. Rev. B* 91, 155115 (2015).
/// <https://doi.org/10.1103/PhysRevB.91.155115> (arXiv:1501.05504).
///
/// # Errors
/// - [`CausalTensorError::ShapeMismatch`] if `A` is not square (`in_dims != out_dims`).
/// - [`CausalTensorError::SweepDidNotConverge`] if the relative residual stays above `tol`.
pub fn eigen<T: ConjugateScalar>(
    a: &CausalTensorTrainOperator<T>,
    max_rank: usize,
    config: &SolveConfig<<T as ConjugateScalar>::Real>,
) -> Result<(T, CausalTensorTrain<T>), CausalTensorError> {
    if a.in_dims() != a.out_dims() {
        return Err(CausalTensorError::ShapeMismatch);
    }
    let exact = Truncation::by_bond(usize::MAX)?;
    let shape = a.in_dims().to_vec();
    let d = shape.len();
    let caps = bond_ranks(&shape, max_rank);
    // Seed at a small rank; subspace expansion grows it toward the eigenvector.
    let seed: Vec<usize> = caps.iter().map(|&r| r.min(2)).collect();
    let mut x = init_random(&shape, &seed, 0xE16E_5017);
    let enrich_trunc = Truncation::new(max_rank, config.tol(), Re::<T>::zero())?;

    for _sweep in 0..config.max_sweeps() {
        // Single-site DMRG sweep. Each site is solved in mixed-canonical gauge (orthogonality
        // center at `k`), so the environment is orthonormal and the local problem is a *standard*
        // Hermitian eigenproblem — no overlap whitening, no ridge, machine-precision accurate.
        for k in forward_then_back(d) {
            let centered =
                CausalTensorTrain::from_cores_raw(x, CanonicalForm::None).canonicalize_at(k)?;
            x = centered.into_cores();
            eigen_site(&mut x, a, k)?;
        }
        // Rayleigh quotient λ = <x|A|x> / <x|x> (real for a Hermitian A) and residual r = A·x − λ·x.
        let xt = CausalTensorTrain::from_cores_raw(x, CanonicalForm::None);
        let xx = xt.inner(&xt)?.real_part();
        if xx <= Re::<T>::zero() {
            return Err(CausalTensorError::SweepDidNotConverge);
        }
        let ax = a.apply(&xt, &exact)?;
        let lambda = xt.inner(&ax)? / T::from_real(xx);
        let res = ax.add(&xt.scale(-lambda))?;
        let rnorm = res.norm()?.real_part() / xx.sqrt();
        if rnorm <= config.tol() {
            // Normalize the eigenvector before returning. No re-truncation here: `xt` already has
            // bond ≤ max_rank from the previous enrichment round, and a tol-based round would drop
            // small-but-real components and inflate the residual.
            let inv = T::from_real(Re::<T>::one() / xx.sqrt());
            return Ok((lambda, xt.scale(inv)));
        }
        // DMRG3S subspace expansion: enrich with the residual direction, capped at max_rank.
        x = xt.add(&res)?.round(&enrich_trunc)?.into_cores();
    }
    Err(CausalTensorError::SweepDidNotConverge)
}

/// Advances a tensor-train state one time step `dt` under the generator `op` (`dx/dt = op·x`) by a
/// **two-site Time-Dependent Variational Principle (TDVP2)** sweep — a single forward sweep over the
/// two-site blocks, rank-adaptive through the SVD split under `trunc`.
///
/// Each block `(k, k+1)` is evolved forward by `exp(+dt·H₂)` (the two-site effective generator), split
/// by a truncated SVD, and the single-site center is evolved back by `exp(−dt·H₁)` to avoid
/// double-counting the shared site — the standard TDVP2 scheme. Every local update is an isometry
/// (the SVD split) or a `exp`-of-generator map (orthogonal when the generator is skew-symmetric), so
/// the step **conserves norm** to the truncation tolerance for a unitary (real skew-symmetric)
/// generator. Two-site (not one-site) so the bond dimension can grow.
///
/// Reference: J. Haegeman, C. Lubich, I. Oseledets, B. Vandereycken, F. Verstraete, "Unifying time
/// evolution and optimization with matrix product states," *Phys. Rev. B* 94, 165116 (2016)
/// (arXiv:1408.5056); review: S. Paeckel et al., *Ann. Phys.* 411, 167998 (2019) (arXiv:1901.05824).
///
/// # Errors
/// - [`CausalTensorError::ShapeMismatch`] if `op` is not square or its dimensions do not match the
///   state's physical dimensions.
/// - Propagates SVD/reshape errors.
pub fn tdvp_step<T: ConjugateScalar>(
    op: &CausalTensorTrainOperator<T>,
    train: &mut CausalTensorTrain<T>,
    dt: T,
    trunc: &Truncation<<T as ConjugateScalar>::Real>,
) -> Result<(), CausalTensorError> {
    if op.in_dims() != op.out_dims() || train.phys_dims() != op.in_dims() {
        return Err(CausalTensorError::ShapeMismatch);
    }
    let d = train.order();
    // Right-canonicalize so the orthogonality center starts at site 0.
    let mut x = train.right_canonicalize()?.into_cores();

    if d == 1 {
        // Single core: evolve by the full effective generator (the operator matrix itself).
        let (h, n) = build_local_h(&x, op, 0);
        let e = expm_scaled(&h, n, dt);
        let shape = x[0].shape().to_vec();
        let v = mat_vec(&e, x[0].as_slice(), n);
        x[0] = CausalTensor::new(v, shape)?;
        *train = CausalTensorTrain::from_cores(x)?;
        return Ok(());
    }

    for k in 0..d - 1 {
        let rk = x[k].shape()[0];
        let nk = x[k].shape()[1];
        let nk1 = x[k + 1].shape()[1];
        let rk2 = x[k + 1].shape()[2];

        // Θ = x[k]·x[k+1] over the shared bond, then forward two-site evolution.
        let theta = contract_two(&x[k], &x[k + 1]);
        let (h2, n2) = build_local_h2(&x, op, k);
        let e2 = expm_scaled(&h2, n2, dt);
        let theta_e = mat_vec(&e2, &theta, n2);

        // Truncated SVD split: x[k] ← U (left-orthonormal); center ← diag(S)·Vt.
        let rows = rk * nk;
        let cols = nk1 * rk2;
        let m = CausalTensor::new(theta_e, vec![rows, cols])?;
        let (u, sv, vt) = m.svd_truncated(trunc)?;
        let q = sv.len();
        x[k] = u.reshape(&[rk, nk, q])?;
        let svs = sv.as_slice();
        let vts = vt.as_slice();
        let mut center = vec![T::zero(); q * cols];
        for a in 0..q {
            let sa = T::from_real(svs[a]); // singular values are real
            for j in 0..cols {
                center[a * cols + j] = sa * vts[a * cols + j];
            }
        }
        x[k + 1] = CausalTensor::new(center, vec![q, nk1, rk2])?;

        // Backward single-site evolution of the center (all blocks but the last).
        if k < d - 2 {
            let (h1, n1) = build_local_h(&x, op, k + 1);
            let e1 = expm_scaled(&h1, n1, -dt);
            let cvec = mat_vec(&e1, x[k + 1].as_slice(), n1);
            x[k + 1] = CausalTensor::new(cvec, vec![q, nk1, rk2])?;
        }
    }
    *train = CausalTensorTrain::from_cores(x)?;
    Ok(())
}

// ============================================================================
// fit internals
// ============================================================================

fn fit_site<T: ConjugateScalar>(
    cores: &mut [CausalTensor<T>],
    shape: &[usize],
    k: usize,
    samples: &[(Vec<usize>, T)],
    ridge: Re<T>,
) {
    let rk = cores[k].shape()[0];
    let nk = shape[k];
    let rkp = cores[k].shape()[2];
    let p = rk * rkp;

    // One block per physical slice i: M_i (p×p), y_i (p).
    let mut blocks_m = vec![vec![T::zero(); p * p]; nk];
    let mut blocks_y = vec![vec![T::zero(); p]; nk];

    for (idx, val) in samples {
        let i0 = idx[k];
        let ls = left_product(cores, idx, k); // length rk
        let rs = right_product(cores, idx, k); // length rkp
        // feature φ[(a,b)] = ls[a]·rs[b]
        let m = &mut blocks_m[i0];
        let y = &mut blocks_y[i0];
        for a in 0..rk {
            for b in 0..rkp {
                let phi = ls[a] * rs[b];
                y[a * rkp + b] += *val * phi;
                for a2 in 0..rk {
                    for b2 in 0..rkp {
                        let phi2 = ls[a2] * rs[b2];
                        m[(a * rkp + b) * p + (a2 * rkp + b2)] += phi * phi2;
                    }
                }
            }
        }
    }

    // Solve each slice and write the new core.
    let mut data = vec![T::zero(); rk * nk * rkp];
    for i in 0..nk {
        let mut m = blocks_m[i].clone();
        for j in 0..p {
            m[j * p + j] += T::from_real(ridge);
        }
        let mut y = blocks_y[i].clone();
        solve_dense(&mut m, &mut y, p);
        for a in 0..rk {
            for b in 0..rkp {
                data[a * (nk * rkp) + i * rkp + b] = y[a * rkp + b];
            }
        }
    }
    cores[k] = CausalTensor::new(data, vec![rk, nk, rkp]).unwrap();
}

/// Left partial product `∏_{j<k} core_j[:, idx_j, :]`, a length-`r_k` row vector.
fn left_product<T: ConjugateScalar>(cores: &[CausalTensor<T>], idx: &[usize], k: usize) -> Vec<T> {
    let mut v = vec![T::one()]; // r_0 == 1
    for (j, core) in cores.iter().enumerate().take(k) {
        let (rl, n, rr) = (core.shape()[0], core.shape()[1], core.shape()[2]);
        let cd = core.as_slice();
        let i = idx[j];
        let mut nv = vec![T::zero(); rr];
        for (a, &va) in v.iter().enumerate().take(rl) {
            if va == T::zero() {
                continue;
            }
            let base = a * (n * rr) + i * rr;
            for (b, nvb) in nv.iter_mut().enumerate() {
                *nvb += va * cd[base + b];
            }
        }
        v = nv;
    }
    v
}

/// Right partial product `∏_{j>k} core_j[:, idx_j, :]`, a length-`r_{k+1}` column vector.
fn right_product<T: ConjugateScalar>(cores: &[CausalTensor<T>], idx: &[usize], k: usize) -> Vec<T> {
    let d = cores.len();
    let mut v = vec![T::one()]; // r_d == 1
    for j in (k + 1..d).rev() {
        let core = &cores[j];
        let (rl, n, rr) = (core.shape()[0], core.shape()[1], core.shape()[2]);
        let cd = core.as_slice();
        let i = idx[j];
        let mut nv = vec![T::zero(); rl];
        for (a, nva) in nv.iter_mut().enumerate() {
            let base = a * (n * rr) + i * rr;
            let mut acc = T::zero();
            for (b, &vb) in v.iter().enumerate().take(rr) {
                acc += cd[base + b] * vb;
            }
            *nva = acc;
        }
        v = nv;
    }
    v
}

fn rms_residual<T: ConjugateScalar>(
    cores: &[CausalTensor<T>],
    samples: &[(Vec<usize>, T)],
) -> Result<Re<T>, CausalTensorError> {
    let train = CausalTensorTrain::from_cores_raw(cores.to_vec(), CanonicalForm::None);
    let mut sum = Re::<T>::zero();
    for (idx, val) in samples {
        let got = train.eval(idx)?;
        // Squared error magnitude (real): |got − val|².
        sum += (got - *val).modulus_squared();
    }
    let n = <Re<T> as deep_causality_num::FromPrimitive>::from_usize(samples.len()).ok_or(
        CausalTensorError::InvalidParameter("sample count".to_string()),
    )?;
    Ok((sum / n).sqrt())
}

// ============================================================================
// linear internals
// ============================================================================

/// Builds the dense single-site effective operator `H_eff` for site `k`:
/// `H[(a,i,b),(a',i',b')] = Σ gl[a,gl_,a']·op[gl_,i,i',gr_]·gr[b,gr_,b']`, the projection of the
/// MPO `op` onto the current cores of `x` at site `k`. Returns the row-major `n×n` matrix
/// (`n = r_k·n_k·r_{k+1}`) and `n`. Shared by the linear solve (`op = AᵀA`) and the DMRG3S
/// eigensolver (`op = A`).
fn build_local_h<T: ConjugateScalar>(
    x: &[CausalTensor<T>],
    op: &CausalTensorTrainOperator<T>,
    k: usize,
) -> (Vec<T>, usize) {
    let rk = x[k].shape()[0];
    let nk = x[k].shape()[1];
    let rkp = x[k].shape()[2];
    let n = rk * nk * rkp;

    // Left/right environments of <x|op|x> (3-index).
    let (gl, gk) = env_g_left(x, op, k); // gl: [rk, gk, rk]
    let (gr, gkp) = env_g_right(x, op, k); // gr: [rkp, gkp, rkp]
    let gcore = &op.cores()[k]; // [gk, nk, nk, gkp]
    let gd = gcore.as_slice();

    let mut hmat = vec![T::zero(); n * n];
    for a in 0..rk {
        for ap in 0..rk {
            for gl_ in 0..gk {
                let lval = gl[(a * gk + gl_) * rk + ap];
                if lval == T::zero() {
                    continue;
                }
                for b in 0..rkp {
                    for bp in 0..rkp {
                        for gr_ in 0..gkp {
                            let rval = gr[(b * gkp + gr_) * rkp + bp];
                            if rval == T::zero() {
                                continue;
                            }
                            let lr = lval * rval;
                            for i in 0..nk {
                                for ip in 0..nk {
                                    let gval = gd[(((gl_ * nk) + i) * nk + ip) * gkp + gr_];
                                    if gval == T::zero() {
                                        continue;
                                    }
                                    let row = (a * nk + i) * rkp + b;
                                    let col = (ap * nk + ip) * rkp + bp;
                                    hmat[row * n + col] += lr * gval;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    (hmat, n)
}

/// One ALS site update for `G x = c`: build the local system from the environments and solve.
fn linear_site<T: ConjugateScalar>(
    x: &mut [CausalTensor<T>],
    g: &CausalTensorTrainOperator<T>,
    c: &CausalTensorTrain<T>,
    k: usize,
    ridge: Re<T>,
) -> Result<(), CausalTensorError> {
    let rk = x[k].shape()[0];
    let nk = x[k].shape()[1];
    let rkp = x[k].shape()[2];

    let (mut hmat, n) = build_local_h(x, g, k);

    // Right-hand-side environments of <x|c> (2-index).
    let cl = env_c_left(x, c, k); // [rk, ck]
    let cr = env_c_right(x, c, k); // [rkp, ckp]
    let ccore = &c.cores()[k]; // [ck, nk, ckp]
    let ck = ccore.shape()[0];
    let ckp = ccore.shape()[2];
    let cd = ccore.as_slice();

    // Local rhs y[(a,i,b)] = Σ cl[a,cl_]·C[cl_,i,cr_]·cr[b,cr_].
    let mut y = vec![T::zero(); n];
    for a in 0..rk {
        for cl_ in 0..ck {
            let lval = cl[a * ck + cl_];
            if lval == T::zero() {
                continue;
            }
            for b in 0..rkp {
                for cr_ in 0..ckp {
                    let rval = cr[b * ckp + cr_];
                    if rval == T::zero() {
                        continue;
                    }
                    for i in 0..nk {
                        let cval = cd[(cl_ * nk + i) * ckp + cr_];
                        y[(a * nk + i) * rkp + b] += lval * cval * rval;
                    }
                }
            }
        }
    }

    for j in 0..n {
        hmat[j * n + j] += T::from_real(ridge);
    }
    solve_dense(&mut hmat, &mut y, n);
    x[k] = CausalTensor::new(y, vec![rk, nk, rkp])?;
    Ok(())
}

/// Left environment of `<x|G|x>` up to (not including) site `k`: shape `[r_k, gG_k, r_k]`.
fn env_g_left<T: ConjugateScalar>(
    x: &[CausalTensor<T>],
    g: &CausalTensorTrainOperator<T>,
    k: usize,
) -> (Vec<T>, usize) {
    // E[a, gl, a'] starting at the boundary [1,1,1] = 1.
    let mut e = vec![T::one()];
    let mut rl = 1usize;
    let mut gl = 1usize;
    for (xc, gc) in x.iter().zip(g.cores().iter()).take(k) {
        let (n, xrr) = (xc.shape()[1], xc.shape()[2]);
        let grr = gc.shape()[3];
        let xd = xc.as_slice();
        let gd = gc.as_slice();
        let mut ne = vec![T::zero(); xrr * grr * xrr];
        for a in 0..rl {
            for gli in 0..gl {
                for ap in 0..rl {
                    let ev = e[(a * gl + gli) * rl + ap];
                    if ev == T::zero() {
                        continue;
                    }
                    for i in 0..n {
                        let xai =
                            xd[a * (n * xrr) + i * xrr..a * (n * xrr) + i * xrr + xrr].to_vec();
                        for ip in 0..n {
                            let gv_base = (((gli * n) + i) * n + ip) * grr;
                            for c in 0..xrr {
                                // Bra side of ⟨x|G|x⟩ is conjugated (identity for real scalars).
                                let xv = xai[c].conjugate();
                                if xv == T::zero() {
                                    continue;
                                }
                                let evx = ev * xv;
                                for grj in 0..grr {
                                    let gv = gd[gv_base + grj];
                                    if gv == T::zero() {
                                        continue;
                                    }
                                    let evxg = evx * gv;
                                    let xpbase = ap * (n * xrr) + ip * xrr;
                                    for cp in 0..xrr {
                                        ne[(c * grr + grj) * xrr + cp] += evxg * xd[xpbase + cp];
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        e = ne;
        rl = xrr;
        gl = grr;
    }
    (e, gl)
}

/// Right environment of `<x|G|x>` from site `k+1`: shape `[r_{k+1}, gG_{k+1}, r_{k+1}]`.
fn env_g_right<T: ConjugateScalar>(
    x: &[CausalTensor<T>],
    g: &CausalTensorTrainOperator<T>,
    k: usize,
) -> (Vec<T>, usize) {
    let d = x.len();
    let mut e = vec![T::one()];
    let mut rr = 1usize;
    let mut gr = 1usize;
    for (xc, gc) in x[k + 1..d].iter().zip(g.cores()[k + 1..d].iter()).rev() {
        let (xrl, n, xrr) = (xc.shape()[0], xc.shape()[1], xc.shape()[2]);
        let grl_ = gc.shape()[0];
        let grr = gc.shape()[3];
        let xd = xc.as_slice();
        let gd = gc.as_slice();
        let mut ne = vec![T::zero(); xrl * grl_ * xrl];
        for a in 0..xrl {
            for gli in 0..grl_ {
                for ap in 0..xrl {
                    let mut acc = T::zero();
                    for i in 0..n {
                        for ip in 0..n {
                            for c in 0..rr {
                                // Bra side of ⟨x|G|x⟩ is conjugated (identity for real scalars).
                                let xv = xd[a * (n * xrr) + i * xrr + c].conjugate();
                                if xv == T::zero() {
                                    continue;
                                }
                                for grj in 0..gr {
                                    let gv = gd[(((gli * n) + i) * n + ip) * grr + grj];
                                    if gv == T::zero() {
                                        continue;
                                    }
                                    for cp in 0..rr {
                                        let ev2 = e[(c * gr + grj) * rr + cp];
                                        acc += xv * gv * ev2 * xd[ap * (n * xrr) + ip * xrr + cp];
                                    }
                                }
                            }
                        }
                    }
                    ne[(a * grl_ + gli) * xrl + ap] = acc;
                }
            }
        }
        e = ne;
        rr = xrl;
        gr = grl_;
    }
    (e, gr)
}

/// Left environment of `<x|c>` up to site `k`: shape `[r_k, c_k]`.
fn env_c_left<T: ConjugateScalar>(
    x: &[CausalTensor<T>],
    c: &CausalTensorTrain<T>,
    k: usize,
) -> Vec<T> {
    let mut e = vec![T::one()];
    let mut rl = 1usize;
    let mut cl = 1usize;
    for (xc, cc) in x.iter().zip(c.cores().iter()).take(k) {
        let (n, xrr) = (xc.shape()[1], xc.shape()[2]);
        let crr = cc.shape()[2];
        let xd = xc.as_slice();
        let cd = cc.as_slice();
        let mut ne = vec![T::zero(); xrr * crr];
        for a in 0..rl {
            for ci in 0..cl {
                let ev = e[a * cl + ci];
                if ev == T::zero() {
                    continue;
                }
                for i in 0..n {
                    for cpp in 0..xrr {
                        // Bra side of ⟨x|c⟩ is conjugated (identity for real scalars).
                        let xv = xd[a * (n * xrr) + i * xrr + cpp].conjugate();
                        if xv == T::zero() {
                            continue;
                        }
                        for cj in 0..crr {
                            ne[cpp * crr + cj] += ev * xv * cd[(ci * n + i) * crr + cj];
                        }
                    }
                }
            }
        }
        e = ne;
        rl = xrr;
        cl = crr;
    }
    e
}

/// Right environment of `<x|c>` from site `k+1`: shape `[r_{k+1}, c_{k+1}]`.
fn env_c_right<T: ConjugateScalar>(
    x: &[CausalTensor<T>],
    c: &CausalTensorTrain<T>,
    k: usize,
) -> Vec<T> {
    let d = x.len();
    let mut e = vec![T::one()];
    let mut rr = 1usize;
    let mut cr = 1usize;
    for (xc, cc) in x[k + 1..d].iter().zip(c.cores()[k + 1..d].iter()).rev() {
        let (xrl, n, xrr) = (xc.shape()[0], xc.shape()[1], xc.shape()[2]);
        let (crl, crr) = (cc.shape()[0], cc.shape()[2]);
        let xd = xc.as_slice();
        let cd = cc.as_slice();
        let mut ne = vec![T::zero(); xrl * crl];
        for a in 0..xrl {
            for ci in 0..crl {
                let mut acc = T::zero();
                for i in 0..n {
                    for cpp in 0..rr {
                        // Bra side of ⟨x|c⟩ is conjugated (identity for real scalars).
                        let xv = xd[a * (n * xrr) + i * xrr + cpp].conjugate();
                        if xv == T::zero() {
                            continue;
                        }
                        for cj in 0..cr {
                            acc += xv * cd[(ci * n + i) * crr + cj] * e[cpp * cr + cj];
                        }
                    }
                }
                ne[a * crl + ci] = acc;
            }
        }
        e = ne;
        rr = xrl;
        cr = crl;
    }
    e
}

// ============================================================================
// eigen internals (DMRG3S)
// ============================================================================

/// One single-site DMRG eigen update at site `k`. **Precondition:** `x` is in mixed-canonical gauge
/// with the orthogonality center at `k`, so the environment is orthonormal and the local problem is a
/// standard symmetric eigenproblem `H z = λ z`. Builds and symmetrizes the local effective operator,
/// takes the smallest eigenpair, and writes the (unit-norm) eigenvector back into the core.
fn eigen_site<T: ConjugateScalar>(
    x: &mut [CausalTensor<T>],
    a: &CausalTensorTrainOperator<T>,
    k: usize,
) -> Result<(), CausalTensorError> {
    let rk = x[k].shape()[0];
    let nk = x[k].shape()[1];
    let rkp = x[k].shape()[2];

    let (mut h, n) = build_local_h(x, a, k);
    symmetrize(&mut h, n);

    let (vals, vecs) = sym_eig(&h, n);
    // Smallest eigenvalue (eigenvalues of a Hermitian matrix are real).
    let mut imin = 0usize;
    for i in 1..n {
        if vals[i].real_part() < vals[imin].real_part() {
            imin = i;
        }
    }
    let y: Vec<T> = (0..n).map(|i| vecs[i * n + imin]).collect();
    x[k] = CausalTensor::new(y, vec![rk, nk, rkp])?;
    Ok(())
}

/// Hermitian-symmetrizes a row-major `n×n` matrix in place: `H ← (H + Hᴴ)/2`, with a real diagonal.
/// For a real scalar the conjugation is the identity and this is the ordinary `(H + Hᵀ)/2`.
fn symmetrize<T: ConjugateScalar>(h: &mut [T], n: usize) {
    let two = T::one() + T::one();
    for i in 0..n {
        for j in (i + 1)..n {
            let avg = (h[i * n + j] + h[j * n + i].conjugate()) / two;
            h[i * n + j] = avg;
            h[j * n + i] = avg.conjugate();
        }
    }
    for i in 0..n {
        h[i * n + i] = T::from_real(h[i * n + i].real_part());
    }
}

// ============================================================================
// tdvp internals (two-site TDVP2)
// ============================================================================

/// Contracts adjacent cores `a [r_k, n_k, m]` and `b [m, n_{k+1}, r_{k+2}]` over the shared bond `m`
/// into the two-site tensor `Θ [r_k, n_k, n_{k+1}, r_{k+2}]` (row-major).
fn contract_two<T: ConjugateScalar>(a: &CausalTensor<T>, b: &CausalTensor<T>) -> Vec<T> {
    let (rk, nk, mk) = (a.shape()[0], a.shape()[1], a.shape()[2]);
    let (nk1, rk2) = (b.shape()[1], b.shape()[2]);
    let ad = a.as_slice();
    let bd = b.as_slice();
    let mut out = vec![T::zero(); rk * nk * nk1 * rk2];
    for i0 in 0..rk {
        for i1 in 0..nk {
            for m in 0..mk {
                let av = ad[(i0 * nk + i1) * mk + m];
                if av == T::zero() {
                    continue;
                }
                for j in 0..nk1 {
                    for r in 0..rk2 {
                        out[((i0 * nk + i1) * nk1 + j) * rk2 + r] +=
                            av * bd[(m * nk1 + j) * rk2 + r];
                    }
                }
            }
        }
    }
    out
}

/// Two-site effective generator at block `(k, k+1)`:
/// `H₂[(a,i,j,b),(a',i',j',b')] = Σ gl[a,gl_,a']·Aₖ[gl_,i,i',m]·Aₖ₊₁[m,j,j',gr_]·gr[b,gr_,b']`.
/// **Precondition:** `x` is mixed-canonical with the block holding the center (orthonormal
/// environment), so this is the true projected generator. Returns the `n₂×n₂` matrix and `n₂`.
fn build_local_h2<T: ConjugateScalar>(
    x: &[CausalTensor<T>],
    op: &CausalTensorTrainOperator<T>,
    k: usize,
) -> (Vec<T>, usize) {
    let rk = x[k].shape()[0];
    let nk = x[k].shape()[1];
    let nk1 = x[k + 1].shape()[1];
    let rk2 = x[k + 1].shape()[2];
    let (gl, gk) = env_g_left(x, op, k); // [rk, gk, rk]
    let (gr, gkp) = env_g_right(x, op, k + 1); // [rk2, gkp, rk2]
    let ak = &op.cores()[k]; // [gk, nk, nk, gm]
    let ak1 = &op.cores()[k + 1]; // [gm, nk1, nk1, gkp]
    let gm = ak.shape()[3];
    let akd = ak.as_slice();
    let ak1d = ak1.as_slice();
    let n2 = rk * nk * nk1 * rk2;

    let mut h = vec![T::zero(); n2 * n2];
    for a in 0..rk {
        for ap in 0..rk {
            for gl_ in 0..gk {
                let lval = gl[(a * gk + gl_) * rk + ap];
                if lval == T::zero() {
                    continue;
                }
                for b in 0..rk2 {
                    for bp in 0..rk2 {
                        for gr_ in 0..gkp {
                            let rval = gr[(b * gkp + gr_) * rk2 + bp];
                            if rval == T::zero() {
                                continue;
                            }
                            let lr = lval * rval;
                            for i in 0..nk {
                                for ip in 0..nk {
                                    for j in 0..nk1 {
                                        for jp in 0..nk1 {
                                            let mut asum = T::zero();
                                            for m in 0..gm {
                                                let akv =
                                                    akd[(((gl_ * nk) + i) * nk + ip) * gm + m];
                                                if akv == T::zero() {
                                                    continue;
                                                }
                                                asum += akv
                                                    * ak1d
                                                        [(((m * nk1) + j) * nk1 + jp) * gkp + gr_];
                                            }
                                            if asum == T::zero() {
                                                continue;
                                            }
                                            let row = ((a * nk + i) * nk1 + j) * rk2 + b;
                                            let col = ((ap * nk + ip) * nk1 + jp) * rk2 + bp;
                                            h[row * n2 + col] += lr * asum;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    (h, n2)
}

/// `exp(dt·M)` for a row-major `n×n` matrix by scaling-and-squaring with an order-18 Taylor series.
/// The matrix is scaled so its norm is `≤ 1/8` before the Taylor sum, then squared back; this reaches
/// machine precision across `f32`/`f64`/`Float106` (the Taylor remainder is `≤ (1/8)^19/19!`).
fn expm_scaled<T: ConjugateScalar>(m: &[T], n: usize, dt: T) -> Vec<T> {
    // B = dt·M.
    let mut b: Vec<T> = m.iter().map(|&x| x * dt).collect();
    // Max-modulus row-sum norm (real).
    let mut norm = Re::<T>::zero();
    for i in 0..n {
        let mut row = Re::<T>::zero();
        for j in 0..n {
            row += b[i * n + j].modulus_squared().sqrt();
        }
        if row > norm {
            norm = row;
        }
    }
    // Scaling exponent from the real norm: scale B by 1/2^s so its norm ≤ 1/8.
    let two_r = Re::<T>::one() + Re::<T>::one();
    let eighth = Re::<T>::one() / (two_r * two_r * two_r);
    let mut s = 0u32;
    let mut scaled = norm;
    while scaled > eighth {
        scaled = scaled / two_r;
        s += 1;
    }
    // Apply the scaling in the scalar type.
    let two = T::one() + T::one();
    let mut pow2 = T::one();
    for _ in 0..s {
        pow2 *= two;
    }
    for x in b.iter_mut() {
        *x = *x / pow2;
    }
    // Taylor: E = I + B + B²/2! + … + B¹⁸/18!.
    let mut e = mat_id::<T>(n);
    let mut term = mat_id::<T>(n);
    for kk in 1..=18u32 {
        let k_t = <T as deep_causality_num::FromPrimitive>::from_u32(kk).unwrap();
        term = mat_mul(&term, &b, n);
        for x in term.iter_mut() {
            *x = *x / k_t;
        }
        for (ei, ti) in e.iter_mut().zip(term.iter()) {
            *ei += *ti;
        }
    }
    // Square s times: exp(B) = (exp(B/2^s))^{2^s}.
    for _ in 0..s {
        e = mat_mul(&e, &e, n);
    }
    e
}

/// Row-major `n×n` identity.
fn mat_id<T: ConjugateScalar>(n: usize) -> Vec<T> {
    let mut m = vec![T::zero(); n * n];
    for i in 0..n {
        m[i * n + i] = T::one();
    }
    m
}

/// Row-major `n×n` matrix product `A·B`.
fn mat_mul<T: ConjugateScalar>(a: &[T], b: &[T], n: usize) -> Vec<T> {
    let mut c = vec![T::zero(); n * n];
    for i in 0..n {
        for p in 0..n {
            let aip = a[i * n + p];
            if aip == T::zero() {
                continue;
            }
            for j in 0..n {
                c[i * n + j] += aip * b[p * n + j];
            }
        }
    }
    c
}

/// Matrix–vector product `M·v` for a row-major `n×n` `M`.
fn mat_vec<T: ConjugateScalar>(m: &[T], v: &[T], n: usize) -> Vec<T> {
    let mut out = vec![T::zero(); n];
    for i in 0..n {
        let mut acc = T::zero();
        for j in 0..n {
            acc += m[i * n + j] * v[j];
        }
        out[i] = acc;
    }
    out
}

// ============================================================================
// shared helpers
// ============================================================================

/// Per-bond ranks: `r_0 = r_d = 1`, interior `r_k = min(max_rank, ∏ left dims, ∏ right dims)`.
fn bond_ranks(shape: &[usize], max_rank: usize) -> Vec<usize> {
    let d = shape.len();
    let mut left = vec![1usize; d + 1];
    for k in 1..=d {
        left[k] = left[k - 1].saturating_mul(shape[k - 1]);
    }
    let mut right = vec![1usize; d + 1];
    for k in (0..d).rev() {
        right[k] = right[k + 1].saturating_mul(shape[k]);
    }
    let mut r = vec![1usize; d + 1];
    for (k, slot) in r.iter_mut().enumerate().take(d).skip(1) {
        *slot = max_rank.min(left[k]).min(right[k]).max(1);
    }
    r
}

/// A deterministically-seeded random train with the given per-bond ranks.
fn init_random<T: ConjugateScalar>(
    shape: &[usize],
    ranks: &[usize],
    seed: u64,
) -> Vec<CausalTensor<T>> {
    let d = shape.len();
    let mut state = seed;
    (0..d)
        .map(|k| {
            let (rl, n, rr) = (ranks[k], shape[k], ranks[k + 1]);
            let data = (0..rl * n * rr).map(|_| rand_unit(&mut state)).collect();
            CausalTensor::new(data, vec![rl, n, rr]).unwrap()
        })
        .collect()
}

/// Forward `0..d` then backward `d-2..=1` site order for one sweep.
fn forward_then_back(d: usize) -> Vec<usize> {
    let mut order: Vec<usize> = (0..d).collect();
    if d >= 2 {
        order.extend((1..d - 1).rev());
    }
    order
}

/// Solves `m·z = y` (row-major `n×n`) by Gaussian elimination with partial pivoting; on return `y`
/// holds `z`. A (near-)singular pivot leaves that component at zero.
fn solve_dense<T: ConjugateScalar>(m: &mut [T], y: &mut [T], n: usize) {
    for col in 0..n {
        let mut piv = col;
        let mut best = m[col * n + col].modulus_squared().sqrt();
        for r in (col + 1)..n {
            let v = m[r * n + col].modulus_squared().sqrt();
            if v > best {
                best = v;
                piv = r;
            }
        }
        if best <= Re::<T>::zero() {
            continue;
        }
        if piv != col {
            for cc in 0..n {
                m.swap(col * n + cc, piv * n + cc);
            }
            y.swap(col, piv);
        }
        let d = m[col * n + col];
        for r in 0..n {
            if r == col {
                continue;
            }
            let factor = m[r * n + col] / d;
            if factor == T::zero() {
                continue;
            }
            for cc in col..n {
                let sub = factor * m[col * n + cc];
                m[r * n + cc] -= sub;
            }
            let sy = factor * y[col];
            y[r] -= sy;
        }
    }
    for col in 0..n {
        let d = m[col * n + col];
        if d != T::zero() {
            y[col] = y[col] / d;
        } else {
            y[col] = T::zero();
        }
    }
}

fn rand_unit<T: ConjugateScalar>(state: &mut u64) -> T {
    // Precision-generic uniform in [-1, 1): sampled at the working precision of `T`, not pinned to f64.
    crate::types::causal_tensor_network::rng::uniform_signed::<T>(state)
}
