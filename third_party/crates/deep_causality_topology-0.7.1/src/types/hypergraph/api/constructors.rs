/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Constructor API for Hypergraph.

use crate::{Hypergraph, TopologyError};
use deep_causality_num::Zero;
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;

impl<T> Hypergraph<T>
where
    T: Default + Copy + Clone + PartialEq + Zero,
{
    /// Creates a new `Hypergraph` from an incidence matrix and node metadata.
    ///
    /// # Arguments
    /// * `incidence` - Incidence matrix (nodes x hyperedges)
    /// * `data` - Tensor data for each node
    /// * `cursor` - Initial cursor position
    ///
    /// # Returns
    /// * `Ok(Hypergraph)` - A valid hypergraph
    /// * `Err(TopologyError)` - If validation fails
    pub fn new(
        incidence: CsrMatrix<i8>,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        Self::new_impl(incidence, data, cursor)
    }
}
