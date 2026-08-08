/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use crate::types::causal_tensor_network::causal_tensor_train_operator::CausalTensorTrainOperator;
use crate::types::causal_tensor_network::truncation::Truncation;
use deep_causality_algebra::ConjugateScalar;

impl<T: ConjugateScalar> CausalTensorTrainOperator<T> {
    /// The cores, in order; core `k` has shape `[r_k, n_out_k, n_in_k, r_{k+1}]`.
    pub fn cores(&self) -> &[CausalTensor<T>] {
        &self.cores
    }

    /// The number of sites.
    pub fn order(&self) -> usize {
        self.cores.len()
    }

    /// The output physical dimensions.
    pub fn out_dims(&self) -> &[usize] {
        &self.out_dims
    }

    /// The input physical dimensions.
    pub fn in_dims(&self) -> &[usize] {
        &self.in_dims
    }

    /// The interior bond dimensions `[r_1, …, r_{order-1}]`.
    pub fn bond_dims(&self) -> Vec<usize> {
        self.cores.iter().skip(1).map(|c| c.shape()[0]).collect()
    }

    /// The largest bond dimension over the whole operator (at least 1).
    pub fn max_bond(&self) -> usize {
        self.cores
            .iter()
            .map(|c| c.shape()[3])
            .chain(core::iter::once(1))
            .max()
            .unwrap_or(1)
    }

    /// The truncation used by the `Arrow::run` realization.
    pub fn round_policy(&self) -> &Truncation<<T as ConjugateScalar>::Real> {
        &self.round_policy
    }
}
