/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of MixedGraph constructors.

use crate::{MixedGraph, TopologyError};
use deep_causality_tensor::CausalTensor;
use std::collections::BTreeMap;

impl<T> MixedGraph<T> {
    /// CPU implementation of the MixedGraph constructor.
    pub(crate) fn new_impl(
        num_vertices: usize,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        if num_vertices == 0 {
            return Err(TopologyError::InvalidInput(
                "MixedGraph must have at least one vertex".to_string(),
            ));
        }

        if data.len() != num_vertices {
            return Err(TopologyError::InvalidInput(
                "Data size must match number of vertices".to_string(),
            ));
        }

        if cursor >= num_vertices {
            return Err(TopologyError::IndexOutOfBounds(
                "Initial cursor out of bounds for MixedGraph".to_string(),
            ));
        }

        Ok(Self {
            num_vertices,
            edges: BTreeMap::new(),
            data,
            cursor,
        })
    }
}
