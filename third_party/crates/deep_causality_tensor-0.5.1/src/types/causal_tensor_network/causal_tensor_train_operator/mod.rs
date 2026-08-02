/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod api;
mod arrow;
mod getters;

use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::truncation::Truncation;
use crate::{CausalTensor, CausalTensorError, Tensor, TensorTrain};
use deep_causality_algebra::ConjugateScalar;

/// A matrix-product operator (MPO) over the same site structure as a
/// [`CausalTensorTrain`](crate::CausalTensorTrain).
///
/// A linear operator `M[(i₀,j₀),…,(i_{d-1},j_{d-1})]` is stored as a chain of rank-4 **cores** `W_k`
/// of shape `[r_k, n_out_k, n_in_k, r_{k+1}]`, boundary bonds `r₀ = r_d = 1`. It maps a train over
/// the input dimensions to a train over the output dimensions.
///
/// The operator carries a `round_policy` [`Truncation`] used by its [`Arrow`](deep_causality_haft::Arrow)
/// realization (`run` = apply-then-round), so `EndoArrow` iteration is a *bounded* time-march. The
/// explicit `apply`/`compose`/`round` methods take their own truncation and ignore this field.
#[derive(Clone, PartialEq)]
pub struct CausalTensorTrainOperator<T: ConjugateScalar> {
    /// Cores `0..order`; core `k` has shape `[r_k, n_out_k, n_in_k, r_{k+1}]`.
    cores: Vec<CausalTensor<T>>,
    /// Output physical dimensions `[n_out_0, …]`.
    out_dims: Vec<usize>,
    /// Input physical dimensions `[n_in_0, …]`.
    in_dims: Vec<usize>,
    /// Truncation used by the `Arrow::run` realization (thresholds live in the real type).
    round_policy: Truncation<<T as ConjugateScalar>::Real>,
}

// Hand-written `Debug` (instead of derived): the associated real type `T::Real` is not guaranteed
// `Debug` by `ConjugateScalar` alone, so the bound is stated explicitly here.
impl<T> core::fmt::Debug for CausalTensorTrainOperator<T>
where
    T: ConjugateScalar + core::fmt::Debug,
    <T as ConjugateScalar>::Real: core::fmt::Debug,
{
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("CausalTensorTrainOperator")
            .field("cores", &self.cores)
            .field("out_dims", &self.out_dims)
            .field("in_dims", &self.in_dims)
            .field("round_policy", &self.round_policy)
            .finish()
    }
}

impl<T> CausalTensorTrainOperator<T>
where
    T: ConjugateScalar,
{
    /// The exact (no-op) truncation: keep every singular value.
    pub(crate) fn exact_truncation() -> Truncation<<T as ConjugateScalar>::Real> {
        Truncation::by_bond(usize::MAX).expect("usize::MAX is a valid bond cap")
    }

    /// Builds an operator from cores and a rounding policy, without validation.
    pub(crate) fn from_cores_raw(
        cores: Vec<CausalTensor<T>>,
        round_policy: Truncation<<T as ConjugateScalar>::Real>,
    ) -> Self {
        let out_dims = cores.iter().map(|c| c.shape()[1]).collect();
        let in_dims = cores.iter().map(|c| c.shape()[2]).collect();
        Self {
            cores,
            out_dims,
            in_dims,
            round_policy,
        }
    }

    /// Builds an operator from an explicit chain of rank-4 cores, validating the bond structure.
    ///
    /// # Errors
    /// - [`CausalTensorError::EmptyTensor`] if `cores` is empty or any core has a zero dimension.
    /// - [`CausalTensorError::DimensionMismatch`] if any core is not 4-dimensional.
    /// - [`CausalTensorError::BondDimensionMismatch`] if the boundary bonds are not 1 or adjacent
    ///   cores disagree on the shared bond.
    pub fn from_cores(cores: Vec<CausalTensor<T>>) -> Result<Self, CausalTensorError> {
        if cores.is_empty() {
            return Err(CausalTensorError::EmptyTensor);
        }
        for core in &cores {
            if core.shape().len() != 4 {
                return Err(CausalTensorError::DimensionMismatch);
            }
            if core.shape().contains(&0) {
                return Err(CausalTensorError::EmptyTensor);
            }
        }
        if cores[0].shape()[0] != 1 || cores[cores.len() - 1].shape()[3] != 1 {
            return Err(CausalTensorError::BondDimensionMismatch);
        }
        for pair in cores.windows(2) {
            if pair[0].shape()[3] != pair[1].shape()[0] {
                return Err(CausalTensorError::BondDimensionMismatch);
            }
        }
        Ok(Self::from_cores_raw(cores, Self::exact_truncation()))
    }

    /// The identity operator on the given physical dimensions: `apply(identity, x) = x`.
    pub fn identity(dims: &[usize]) -> Self {
        let cores = dims
            .iter()
            .map(|&n| {
                let mut data = vec![T::zero(); n * n];
                for i in 0..n {
                    data[i * n + i] = T::one();
                }
                CausalTensor::new(data, vec![1, n, n, 1]).unwrap()
            })
            .collect();
        Self::from_cores_raw(cores, Self::exact_truncation())
    }

    /// Factors a dense operator into an MPO via operator TT-SVD.
    ///
    /// `dense` must be in **site-interleaved** layout `[out_0, in_0, …, out_{d-1}, in_{d-1}]`.
    ///
    /// # Errors
    /// - [`CausalTensorError::ShapeMismatch`] if `dense`'s shape does not match the interleaved
    ///   `out_dims`/`in_dims`.
    /// - Propagates SVD/reshape errors.
    pub fn from_dense(
        dense: &CausalTensor<T>,
        out_dims: &[usize],
        in_dims: &[usize],
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError> {
        if out_dims.len() != in_dims.len() || out_dims.is_empty() {
            return Err(CausalTensorError::ShapeMismatch);
        }
        // Expected interleaved shape.
        let mut expected = Vec::with_capacity(out_dims.len() * 2);
        for (o, i) in out_dims.iter().zip(in_dims.iter()) {
            expected.push(*o);
            expected.push(*i);
        }
        if dense.shape() != expected.as_slice() {
            return Err(CausalTensorError::ShapeMismatch);
        }

        // Merge each (out_k, in_k) pair into a combined physical index, TT-SVD as a state, then
        // split each rank-3 core back into a rank-4 operator core.
        let combined: Vec<usize> = out_dims.iter().zip(in_dims).map(|(o, i)| o * i).collect();
        let dense_combined = dense.reshape(&combined)?;
        let train = CausalTensorTrain::from_dense(&dense_combined, trunc)?;

        let cores = train
            .cores()
            .iter()
            .enumerate()
            .map(|(k, c)| {
                let (r, _p, rp) = (c.shape()[0], c.shape()[1], c.shape()[2]);
                c.reshape(&[r, out_dims[k], in_dims[k], rp])
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self::from_cores_raw(cores, Self::exact_truncation()))
    }

    /// Sums two operators on the same physical dimensions: `(a.add(b))·x = a·x + b·x`.
    ///
    /// The operators form an algebra — this completes it alongside `compose` (operator product) and
    /// `scale`. Realized as the tensor-train sum of the combined-index views, so the bond dimensions
    /// add (`r ← rₐ + r_b`); call [`round`](crate::TensorTrainOperator::round) afterwards to recompress
    /// (e.g. assembling a finite-difference Laplacian `(S₊ + S₋ − 2·I)/Δx²` from shift operators).
    ///
    /// # Errors
    /// [`CausalTensorError::ShapeMismatch`] if the operators disagree on input or output dimensions.
    pub fn add(&self, other: &Self) -> Result<Self, CausalTensorError> {
        if self.out_dims != other.out_dims || self.in_dims != other.in_dims {
            return Err(CausalTensorError::ShapeMismatch);
        }
        let sum = self.as_combined_train().add(&other.as_combined_train())?;
        Self::from_combined_train(&sum, &self.out_dims, &self.in_dims, self.round_policy)
    }

    /// Scales the operator by a scalar: `(a.scale(s))·x = s·(a·x)` (exact, rank-preserving).
    pub fn scale(&self, s: T) -> Self {
        let scaled = self.as_combined_train().scale(s);
        Self::from_combined_train(&scaled, &self.out_dims, &self.in_dims, self.round_policy)
            .expect("scale preserves the operator's bond structure")
    }

    /// Negates the operator (the additive inverse): `(a.neg())·x = −(a·x)`.
    pub fn neg(&self) -> Self {
        self.scale(T::zero() - T::one())
    }

    /// Difference of two operators: `(a.sub(b))·x = a·x − b·x`. Completes the additive group alongside
    /// `add`/`neg` (e.g. a centered first difference `(S₊ − S₋)/2Δx` from two shift operators).
    ///
    /// # Errors
    /// [`CausalTensorError::ShapeMismatch`] if the operators disagree on input or output dimensions.
    pub fn sub(&self, other: &Self) -> Result<Self, CausalTensorError> {
        self.add(&other.neg())
    }

    /// Sets the rounding policy used by the `Arrow::run` realization.
    pub fn with_rounding(mut self, trunc: Truncation<<T as ConjugateScalar>::Real>) -> Self {
        self.round_policy = trunc;
        self
    }

    /// Views the operator as a state train over the combined `(out, in)` physical indices, reusing
    /// the `CausalTensorTrain` algorithms (round / to_dense).
    pub(crate) fn as_combined_train(&self) -> CausalTensorTrain<T> {
        let cores = self
            .cores
            .iter()
            .map(|c| {
                let s = c.shape();
                c.reshape(&[s[0], s[1] * s[2], s[3]]).unwrap()
            })
            .collect();
        CausalTensorTrain::from_cores_raw(cores, CanonicalForm::None)
    }

    /// Rebuilds an operator from a combined-index state train and the out/in split.
    pub(crate) fn from_combined_train(
        train: &CausalTensorTrain<T>,
        out_dims: &[usize],
        in_dims: &[usize],
        round_policy: Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError> {
        let cores = train
            .cores()
            .iter()
            .enumerate()
            .map(|(k, c)| {
                let s = c.shape();
                c.reshape(&[s[0], out_dims[k], in_dims[k], s[2]])
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self::from_cores_raw(cores, round_policy))
    }
}
