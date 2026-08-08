/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Constructor API for Graph.

use crate::{Graph, TopologyError};
use deep_causality_num::Zero;
use deep_causality_tensor::CausalTensor;

impl<T> Graph<T>
where
    T: Default + Copy + Clone + PartialEq + Zero,
{
    /// Creates a new empty `Graph` with a specified number of vertices.
    ///
    /// # Arguments
    /// * `num_vertices` - Number of vertices in the graph
    /// * `data` - Tensor data associated with vertices
    /// * `cursor` - Initial cursor position
    ///
    /// # Returns
    /// * `Ok(Graph)` - A valid graph
    /// * `Err(TopologyError)` - If validation fails
    pub fn new(
        num_vertices: usize,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        Self::new_impl(num_vertices, data, cursor)
    }
}
