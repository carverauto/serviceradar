/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of Graph constructors.

use crate::{Graph, TopologyError};
use deep_causality_num::Zero;
use deep_causality_tensor::CausalTensor;
use std::collections::BTreeMap;

impl<T> Graph<T>
where
    T: Default + Copy + Clone + PartialEq + Zero,
{
    /// CPU implementation of Graph constructor.
    pub(crate) fn new_impl(
        num_vertices: usize,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        if num_vertices == 0 {
            return Err(TopologyError::InvalidInput(
                "Graph must have at least one vertex".to_string(),
            ));
        }

        if data.len() != num_vertices {
            return Err(TopologyError::InvalidInput(
                "Data size must match number of vertices".to_string(),
            ));
        }

        if cursor >= num_vertices {
            return Err(TopologyError::IndexOutOfBounds(
                "Initial cursor out of bounds for Graph".to_string(),
            ));
        }

        let mut adjacencies = BTreeMap::new();
        for i in 0..num_vertices {
            adjacencies.insert(i, Vec::new());
        }

        Ok(Self {
            num_vertices,
            adjacencies,
            num_edges: 0,
            data,
            cursor,
        })
    }
}
