/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::truncation::Truncation;
use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::ConjugateScalar;

/// Behaviour of a matrix-product operator (MPO) over the same site structure as a
/// [`CausalTensorTrain`](crate::CausalTensorTrain).
///
/// Cores are rank-4 `[r_k, n_out_k, n_in_k, r_{k+1}]`. The operator maps a train over its input
/// physical dimensions to a train over its output physical dimensions. Composition (`apply` /
/// `compose`) grows bond dimension exactly and is paired with a [`Truncation`] for recompression;
/// the laws hold exactly without truncation and to the truncation tolerance otherwise.
pub trait TensorTrainOperator<T: ConjugateScalar>: Sized {
    /// Applies the operator to a state train (MPO · MPS), then rounds to `trunc`.
    ///
    /// # Errors
    /// [`CausalTensorError::ShapeMismatch`] if the state's physical dimensions differ from the
    /// operator's input dimensions.
    fn apply(
        &self,
        state: &CausalTensorTrain<T>,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<CausalTensorTrain<T>, CausalTensorError>;

    /// Composes two operators (MPO · MPO, `self` after `other` is *not* implied — this is
    /// `self ∘ other` acting as `self(other(·))`), then rounds to `trunc`.
    ///
    /// # Errors
    /// [`CausalTensorError::ShapeMismatch`] if `self`'s input dimensions differ from `other`'s
    /// output dimensions.
    fn compose(
        &self,
        other: &Self,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError>;

    /// Recompresses the operator to `trunc`.
    fn round(
        &self,
        trunc: &Truncation<<T as ConjugateScalar>::Real>,
    ) -> Result<Self, CausalTensorError>;

    /// The transpose operator (swaps the input and output physical legs of every core).
    fn transpose(&self) -> Self;

    /// Contracts the operator to a dense tensor of shape
    /// `[out_0, in_0, out_1, in_1, …, out_{d-1}, in_{d-1}]` (site-interleaved).
    ///
    /// # Errors
    /// [`CausalTensorError::RankExceeded`] if the dense tensor would exceed the element-count guard.
    fn to_dense(&self) -> Result<CausalTensor<T>, CausalTensorError>;
}
