/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Getter methods for Graph fields.

use crate::Graph;
use deep_causality_tensor::CausalTensor;
use std::collections::BTreeMap;

impl<T> Graph<T> {
    /// Returns the number of vertices in the graph.
    pub fn num_vertices(&self) -> usize {
        self.num_vertices
    }

    /// Returns the number of edges in the graph.
    pub fn num_edges(&self) -> usize {
        self.num_edges
    }

    /// Returns a reference to the adjacency list.
    pub fn adjacencies(&self) -> &BTreeMap<usize, Vec<usize>> {
        &self.adjacencies
    }

    /// Returns a reference to the data tensor.
    pub fn data(&self) -> &CausalTensor<T> {
        &self.data
    }
}
