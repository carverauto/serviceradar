/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod cross;

use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::truncation::Truncation;
use crate::{CausalTensor, CausalTensorError, Tensor};
use deep_causality_algebra::ConjugateScalar;

/// Guard on dense materialization: constructors/contractions that would form more than this many
/// elements fail with [`CausalTensorError::RankExceeded`] rather than allocate `nᵈ`.
pub(crate) const MAX_DENSE_ELEMS: usize = 1 << 24; // 16,777,216

impl<T> CausalTensorTrain<T>
where
    T: ConjugateScalar,
{
    /// Factors a dense tensor into a tensor train by a left-to-right truncated-SVD sweep (TT-SVD).
    ///
    /// # Reference
    /// I. V. Oseledets, "Tensor-train decomposition," *SIAM J. Sci. Comput.* 33(5), 2295–2317
    /// (2011). <https://doi.org/10.1137/090752286> (arXiv:1006.4131) — the TT format and the
    /// sequential-SVD construction implemented here.
    ///
    /// # Errors
    /// - [`CausalTensorError::EmptyTensor`] if `dense` has rank 0 or any zero dimension.
    /// - Propagates SVD/reshape errors.
    pub fn from_dense(
        dense: &CausalTensor<T>,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError> {
        let shape = dense.shape().to_vec();
        if shape.is_empty() || shape.contains(&0) {
            return Err(CausalTensorError::EmptyTensor);
        }
        let d = shape.len();

        // An order-1 tensor is a single rank-1 core.
        if d == 1 {
            let core = CausalTensor::new(dense.as_slice().to_vec(), vec![1, shape[0], 1])?;
            return Ok(Self::from_cores_unchecked(vec![core], CanonicalForm::None));
        }

        let mut cores: Vec<CausalTensor<T>> = Vec::with_capacity(d);
        let mut remaining = dense.as_slice().to_vec();
        let mut r_prev = 1usize;

        for &n_k in shape.iter().take(d - 1) {
            let rows = r_prev * n_k;
            let cols = remaining.len() / rows;

            let m = CausalTensor::new(remaining, vec![rows, cols])?;
            let (u, s, vt) = m.svd_truncated(trunc)?;
            let q = s.len();

            // Core k = U reshaped to [r_prev, n_k, q].
            let core_k = u.reshape(&[r_prev, n_k, q])?;
            cores.push(core_k);

            // remaining = diag(S) · Vt, shape [q, cols].
            let s_slice = s.as_slice();
            let vt_slice = vt.as_slice();
            let mut next = vec![T::zero(); q * cols];
            for a in 0..q {
                // Singular values are real; inject into the scalar type before scaling Vᴴ.
                let sa = T::from_real(s_slice[a]);
                for j in 0..cols {
                    next[a * cols + j] = sa * vt_slice[a * cols + j];
                }
            }
            remaining = next;
            r_prev = q;
        }

        // Last core: remaining is [r_prev, n_{d-1}].
        let n_last = shape[d - 1];
        let last = CausalTensor::new(remaining, vec![r_prev, n_last, 1])?;
        cores.push(last);

        Ok(Self::from_cores_unchecked(cores, CanonicalForm::None))
    }

    /// Builds a tensor train from an index→value closure: materializes the (guarded) dense tensor,
    /// then applies TT-SVD.
    ///
    /// # Errors
    /// - [`CausalTensorError::EmptyTensor`] if `shape` is empty or has a zero dimension.
    /// - [`CausalTensorError::RankExceeded`] if the dense tensor would exceed `MAX_DENSE_ELEMS`.
    pub fn from_fn<F>(
        shape: &[usize],
        f: F,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError>
    where
        F: FnMut(&[usize]) -> T,
    {
        if shape.is_empty() || shape.contains(&0) {
            return Err(CausalTensorError::EmptyTensor);
        }
        let total: usize = shape.iter().product();
        if total > MAX_DENSE_ELEMS {
            return Err(CausalTensorError::RankExceeded);
        }
        let dense = CausalTensor::from_shape_fn(shape, f);
        Self::from_dense(&dense, trunc)
    }
}
