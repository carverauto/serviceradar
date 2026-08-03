/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::causal_tensor_train::linalg::matmul;
use crate::types::causal_tensor_network::cross_config::CrossConfig;
use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::{ConjugateScalar, Real};
use deep_causality_num::Zero;

/// The real magnitude type of a conjugate scalar.
type Re<T> = <T as ConjugateScalar>::Real;

/// A list of multi-indices (each a fixed-length `Vec<usize>`).
type IndexSet = Vec<Vec<usize>>;

impl<T> CausalTensorTrain<T>
where
    T: ConjugateScalar,
{
    /// Builds a tensor train from an oracle `f(index) -> value` **without forming the dense
    /// tensor**, via TT-cross (alternating maxvol-style index selection).
    ///
    /// The oracle is queried only on cross fibers; the dense `nᵈ` buffer is never allocated. The
    /// bond dimensions adapt to the numerical rank (capped by [`CrossConfig::rank_cap`]). Returns
    /// the train together with a sampled relative-residual estimate.
    ///
    /// # References
    /// - I. V. Oseledets and E. E. Tyrtyshnikov, "TT-cross approximation for multidimensional
    ///   arrays," *Linear Algebra Appl.* 432(1), 70–88 (2010).
    ///   <https://doi.org/10.1016/j.laa.2009.07.024> — the alternating cross interpolation scheme.
    /// - S. A. Goreinov, I. V. Oseledets, D. V. Savostyanov, E. E. Tyrtyshnikov, and N. L.
    ///   Zamarashkin, "How to find a good submatrix," in *Matrix Methods: Theory, Algorithms and
    ///   Applications* (World Scientific, 2010), pp. 247–256 — the maxvol index-selection principle
    ///   underlying the rank-revealing pivots.
    ///
    /// # Errors
    /// - [`CausalTensorError::EmptyTensor`] if `shape` is empty or has a zero dimension.
    /// - [`CausalTensorError::CrossSampleFailure`] if the oracle returns a non-finite value.
    /// - [`CausalTensorError::SingularMatrix`] if an interpolation submatrix is singular.
    pub fn cross<F>(
        shape: &[usize],
        mut oracle: F,
        config: &CrossConfig<<T as ConjugateScalar>::Real>,
    ) -> Result<(Self, <T as ConjugateScalar>::Real), CausalTensorError>
    where
        F: FnMut(&[usize]) -> T,
    {
        let d = shape.len();
        if d == 0 || shape.contains(&0) {
            return Err(CausalTensorError::EmptyTensor);
        }

        // Order-1: the train is just the sampled vector.
        if d == 1 {
            let n = shape[0];
            let mut data = Vec::with_capacity(n);
            for i in 0..n {
                let val = oracle(&[i]);
                if !val.modulus_squared().is_finite() {
                    return Err(CausalTensorError::CrossSampleFailure);
                }
                data.push(val);
            }
            let core = CausalTensor::new(data, vec![1, n, 1])?;
            return Ok((
                Self::from_cores_unchecked(vec![core], CanonicalForm::None),
                Re::<T>::zero(),
            ));
        }

        // Per-bond rank caps: r_k ≤ min(rank_cap, ∏ left dims, ∏ right dims).
        let mut left_size = vec![1usize; d + 1];
        for k in 1..=d {
            left_size[k] = left_size[k - 1].saturating_mul(shape[k - 1]);
        }
        let mut right_size = vec![1usize; d + 1];
        for k in (0..d).rev() {
            right_size[k] = right_size[k + 1].saturating_mul(shape[k]);
        }
        let cap = |k: usize| {
            config
                .rank_cap()
                .min(left_size[k])
                .min(right_size[k])
                .max(1)
        };

        let mut state = config.seed();

        // Initialize right index sets with random distinct multi-indices (rank up to the cap).
        // right[k] indexes sites k..d-1; right[d] = {()}.
        let mut right: Vec<IndexSet> = vec![Vec::new(); d + 1];
        right[d] = vec![vec![]];
        for k in (1..d).rev() {
            right[k] = random_multi_indices(&shape[k..d], cap(k), &mut state);
        }

        // Alternate L→R / R→L sweeps refining the index sets until the right sets stabilize.
        let mut left: Vec<IndexSet> = vec![Vec::new(); d + 1];
        left[0] = vec![vec![]];
        for _sweep in 0..config.max_sweeps() {
            // L→R: rebuild left sets from the current right sets.
            for k in 0..d - 1 {
                let c = eval_cross(shape, &left[k], k, &right[k + 1], &mut oracle)?;
                let nk = shape[k];
                let rcols = right[k + 1].len();
                let pivots = pivot_rows(&c.0, c.1, rcols, cap(k + 1));
                left[k + 1] = extend_left(&left[k], nk, &pivots);
            }
            // R→L: rebuild right sets from the current left sets.
            let prev_right = right.clone();
            for k in (1..d).rev() {
                let dmat = eval_cross_right(shape, &left[k], k, &right[k + 1], &mut oracle)?;
                let rk = left[k].len();
                let pivots = pivot_rows(&dmat.0, dmat.1, rk, cap(k));
                right[k] = extend_right(&right[k + 1], &pivots);
            }
            if right == prev_right {
                break;
            }
        }

        // Final interpolatory L→R pass building the cores from the converged right sets.
        let cores = build_cores(shape, &right, &mut oracle)?;
        let train = Self::from_cores(cores)?;
        let residual = estimate_residual(&train, shape, &mut oracle, config, &mut state)?;
        Ok((train, residual))
    }
}

/// Evaluates the cross matrix `C[(α,i), β] = f(left[α] ++ [i] ++ right[β])` for the L→R sweep at
/// site `k`. Returns `(data, rows)` with `rows = left.len() * shape[k]`, `cols = right.len()`.
fn eval_cross<T, F>(
    shape: &[usize],
    left: &IndexSet,
    k: usize,
    right: &IndexSet,
    oracle: &mut F,
) -> Result<(Vec<T>, usize), CausalTensorError>
where
    T: ConjugateScalar,
    F: FnMut(&[usize]) -> T,
{
    let nk = shape[k];
    let rcols = right.len();
    let rows = left.len() * nk;
    let mut c = vec![T::zero(); rows * rcols];
    let mut full = vec![0usize; shape.len()];
    for (a, lidx) in left.iter().enumerate() {
        for i in 0..nk {
            for (b, ridx) in right.iter().enumerate() {
                fill_index(&mut full, lidx, i, ridx);
                let val = oracle(&full);
                if !val.modulus_squared().is_finite() {
                    return Err(CausalTensorError::CrossSampleFailure);
                }
                c[(a * nk + i) * rcols + b] = val;
            }
        }
    }
    Ok((c, rows))
}

/// Evaluates the cross matrix `D[(i,β), α] = f(left[α] ++ [i] ++ right[β])` for the R→L sweep at
/// site `k`. Returns `(data, rows)` with `rows = shape[k] * right.len()`, `cols = left.len()`.
fn eval_cross_right<T, F>(
    shape: &[usize],
    left: &IndexSet,
    k: usize,
    right: &IndexSet,
    oracle: &mut F,
) -> Result<(Vec<T>, usize), CausalTensorError>
where
    T: ConjugateScalar,
    F: FnMut(&[usize]) -> T,
{
    let nk = shape[k];
    let rright = right.len();
    let rk = left.len();
    let rows = nk * rright;
    let mut dmat = vec![T::zero(); rows * rk];
    let mut full = vec![0usize; shape.len()];
    for i in 0..nk {
        for (b, ridx) in right.iter().enumerate() {
            for (a, lidx) in left.iter().enumerate() {
                fill_index(&mut full, lidx, i, ridx);
                let val = oracle(&full);
                if !val.modulus_squared().is_finite() {
                    return Err(CausalTensorError::CrossSampleFailure);
                }
                dmat[(i * rright + b) * rk + a] = val;
            }
        }
    }
    Ok((dmat, rows))
}

/// Final interpolatory pass: `core_k = C_k · Q_k⁻¹` (last core un-normalized), where `Q_k` is the
/// square submatrix of `C_k` on the pivot rows. Left sets are derived fresh from the fixed right
/// sets so every interpolation submatrix is square and the bonds line up.
fn build_cores<T, F>(
    shape: &[usize],
    right: &[IndexSet],
    oracle: &mut F,
) -> Result<Vec<CausalTensor<T>>, CausalTensorError>
where
    T: ConjugateScalar,
    F: FnMut(&[usize]) -> T,
{
    let d = shape.len();
    let mut cores = Vec::with_capacity(d);
    let mut left: IndexSet = vec![vec![]];

    for k in 0..d {
        let nk = shape[k];
        let rk = left.len();
        let (c, rows) = eval_cross(shape, &left, k, &right[k + 1], oracle)?;
        let rcols = right[k + 1].len();

        if k < d - 1 {
            let pivots = pivot_rows(&c, rows, rcols, rcols);
            // Gather the square submatrix Q on the pivot rows.
            let rkp = pivots.len();
            let mut q = vec![T::zero(); rkp * rcols];
            for (m, &p) in pivots.iter().enumerate() {
                q[m * rcols..m * rcols + rcols].copy_from_slice(&c[p * rcols..p * rcols + rcols]);
            }
            // Bonds line up only when the submatrix is square (numerical rank == rcols).
            if rkp != rcols {
                return Err(CausalTensorError::SingularMatrix);
            }
            let qinv = invert_square(&q, rcols).ok_or(CausalTensorError::SingularMatrix)?;
            let core_data = matmul(&c, rows, rcols, &qinv, rcols);
            cores.push(CausalTensor::new(core_data, vec![rk, nk, rcols])?);
            left = extend_left(&left, nk, &pivots);
        } else {
            // Last core: C_{d-1} is [r·n, 1]; no interpolation.
            cores.push(CausalTensor::new(c, vec![rk, nk, 1])?);
        }
    }
    Ok(cores)
}

/// Writes `left ++ [i] ++ right` into `full` (length = order).
fn fill_index(full: &mut [usize], left: &[usize], i: usize, right: &[usize]) {
    full[..left.len()].copy_from_slice(left);
    full[left.len()] = i;
    full[left.len() + 1..].copy_from_slice(right);
}

/// New left set: for each pivot row `p = a·n + i`, the index `left[a] ++ [i]`.
fn extend_left(left: &IndexSet, n: usize, pivots: &[usize]) -> IndexSet {
    pivots
        .iter()
        .map(|&p| {
            let (a, i) = (p / n, p % n);
            let mut idx = left[a].clone();
            idx.push(i);
            idx
        })
        .collect()
}

/// New right set: for each pivot row `p = i·rright + b`, the index `[i] ++ right[b]`.
fn extend_right(right: &IndexSet, pivots: &[usize]) -> IndexSet {
    let rright = right.len();
    pivots
        .iter()
        .map(|&p| {
            let (i, b) = (p / rright, p % rright);
            let mut idx = Vec::with_capacity(right[b].len() + 1);
            idx.push(i);
            idx.extend_from_slice(&right[b]);
            idx
        })
        .collect()
}

/// Selects up to `target` independent pivot rows of a row-major `rows × cols` matrix by Gaussian
/// elimination with partial pivoting (rank-revealing). Returns the pivot row indices.
fn pivot_rows<T: ConjugateScalar>(a: &[T], rows: usize, cols: usize, target: usize) -> Vec<usize> {
    let limit = target.min(cols).min(rows);
    let mut work = a.to_vec();
    let mut used = vec![false; rows];
    let mut pivots = Vec::with_capacity(limit);

    // Relative rank-detection threshold: after Gaussian elimination the residual of a rank-deficient
    // matrix is ~ machine-eps · scale, not exactly zero, so an exact `> 0` test would keep selecting
    // noise rows and inflate the rank. Break once the best remaining pivot drops below this.
    let mut max_abs = Re::<T>::zero();
    for &x in a {
        let ax = x.modulus_squared().sqrt();
        if ax > max_abs {
            max_abs = ax;
        }
    }
    let mut threshold = max_abs * Re::<T>::epsilon();
    for _ in 0..6 {
        threshold = threshold + threshold; // · 64
    }

    for c in 0..limit {
        // Largest-magnitude unused entry in column c.
        let mut best: Option<usize> = None;
        let mut best_val = Re::<T>::zero();
        for (r, &is_used) in used.iter().enumerate() {
            if is_used {
                continue;
            }
            let val = work[r * cols + c].modulus_squared().sqrt();
            if best.is_none() || val > best_val {
                best_val = val;
                best = Some(r);
            }
        }
        let p = match best {
            Some(p) if best_val > threshold => p,
            _ => break, // rank exhausted
        };
        used[p] = true;
        pivots.push(p);

        // Eliminate column c from the other unused rows.
        let piv = work[p * cols + c];
        for r in 0..rows {
            if used[r] {
                continue;
            }
            let factor = work[r * cols + c] / piv;
            if factor == T::zero() {
                continue;
            }
            for cc in c..cols {
                let sub = factor * work[p * cols + cc];
                work[r * cols + cc] -= sub;
            }
        }
    }
    pivots
}

/// Inverts a square `n × n` row-major matrix by Gauss–Jordan elimination with partial pivoting.
/// Returns `None` if singular. Bound on `Scalar` (so it admits the dual scalar), unlike
/// `CausalTensor::inverse`.
fn invert_square<T: ConjugateScalar>(a: &[T], n: usize) -> Option<Vec<T>> {
    let mut m = a.to_vec();
    let mut inv = vec![T::zero(); n * n];
    for i in 0..n {
        inv[i * n + i] = T::one();
    }
    for col in 0..n {
        // Partial pivot by modulus.
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
            return None;
        }
        if piv != col {
            for c in 0..n {
                m.swap(col * n + c, piv * n + c);
                inv.swap(col * n + c, piv * n + c);
            }
        }
        let d = m[col * n + col];
        for c in 0..n {
            m[col * n + c] = m[col * n + c] / d;
            inv[col * n + c] = inv[col * n + c] / d;
        }
        for r in 0..n {
            if r == col {
                continue;
            }
            let factor = m[r * n + col];
            if factor == T::zero() {
                continue;
            }
            for c in 0..n {
                let sm = factor * m[col * n + c];
                m[r * n + c] -= sm;
                let si = factor * inv[col * n + c];
                inv[r * n + c] -= si;
            }
        }
    }
    Some(inv)
}

/// Estimates the relative residual `max|f(idx) − train.eval(idx)| / (max|f| + ε)` on
/// `check_samples` random indices.
fn estimate_residual<T, F>(
    train: &CausalTensorTrain<T>,
    shape: &[usize],
    oracle: &mut F,
    config: &CrossConfig<<T as ConjugateScalar>::Real>,
    state: &mut u64,
) -> Result<<T as ConjugateScalar>::Real, CausalTensorError>
where
    T: ConjugateScalar,
    F: FnMut(&[usize]) -> T,
{
    use crate::TensorTrain;
    let mut max_err = Re::<T>::zero();
    let mut max_val = Re::<T>::zero();
    let mut idx = vec![0usize; shape.len()];
    for _ in 0..config.check_samples() {
        for (slot, &n) in idx.iter_mut().zip(shape.iter()) {
            *slot = rand_below(state, n);
        }
        let want = oracle(&idx);
        if !want.modulus_squared().is_finite() {
            return Err(CausalTensorError::CrossSampleFailure);
        }
        let got = train.eval(&idx)?;
        // Magnitudes are real moduli.
        let err = (want - got).modulus_squared().sqrt();
        if err > max_err {
            max_err = err;
        }
        let av = want.modulus_squared().sqrt();
        if av > max_val {
            max_val = av;
        }
    }
    Ok(max_err / (max_val + Re::<T>::epsilon()))
}

/// `count` distinct random multi-indices over `dims` (or all of them if fewer exist).
fn random_multi_indices(dims: &[usize], count: usize, state: &mut u64) -> IndexSet {
    let total: usize = dims.iter().product();
    let target = count.min(total).max(1);
    let mut out: IndexSet = Vec::with_capacity(target);
    let mut attempts = 0usize;
    while out.len() < target && attempts < target * 32 + 16 {
        attempts += 1;
        let idx: Vec<usize> = dims.iter().map(|&n| rand_below(state, n)).collect();
        if !out.contains(&idx) {
            out.push(idx);
        }
    }
    out
}

/// splitmix64 step.
fn next_u64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

fn rand_below(state: &mut u64, bound: usize) -> usize {
    if bound <= 1 {
        return 0;
    }
    (next_u64(state) % bound as u64) as usize
}
