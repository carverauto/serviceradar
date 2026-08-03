/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Constructor API for MixedGraph.

use crate::{MixedGraph, TopologyError};
use deep_causality_tensor::CausalTensor;

impl<T> MixedGraph<T> {
    /// Creates a new edgeless `MixedGraph` with `num_vertices` nodes.
    ///
    /// # Arguments
    /// * `num_vertices` - number of nodes (must be ≥ 1)
    /// * `data` - per-node payload tensor (length must equal `num_vertices`)
    /// * `cursor` - initial comonadic focus (must be `< num_vertices`)
    ///
    /// # Returns
    /// * `Ok(MixedGraph)` on success
    /// * `Err(TopologyError)` if a precondition is violated
    pub fn new(
        num_vertices: usize,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        Self::new_impl(num_vertices, data, cursor)
    }
}
