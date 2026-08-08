/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;

impl<T> CausalTensorTrain<T> {
    /// The cores, in order; core `k` has shape `[r_k, n_k, r_{k+1}]`.
    pub fn cores(&self) -> &[CausalTensor<T>] {
        &self.cores
    }

    /// The number of sites (the order of the represented tensor).
    pub fn order(&self) -> usize {
        self.cores.len()
    }

    /// The physical dimensions `[n_0, …, n_{order-1}]`.
    pub fn phys_dims(&self) -> &[usize] {
        &self.phys_dims
    }

    /// The interior bond dimensions `[r_1, …, r_{order-1}]` (the boundary bonds `r_0 = r_order = 1`
    /// are omitted). Empty for an order-1 train.
    pub fn bond_dims(&self) -> Vec<usize> {
        self.cores.iter().skip(1).map(|c| c.shape()[0]).collect()
    }

    /// The largest bond dimension over the whole train (at least 1).
    pub fn max_bond(&self) -> usize {
        self.cores
            .iter()
            .map(|c| c.shape()[2])
            .chain(core::iter::once(1))
            .max()
            .unwrap_or(1)
    }

    /// The tracked orthogonality structure.
    pub fn canonical_form(&self) -> CanonicalForm {
        self.canonical
    }
}
