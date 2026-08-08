/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Graph operations API.

use crate::{Graph, TopologyError};
use deep_causality_num::Zero;
impl<T> Graph<T>
where
    T: Default + Copy + Clone + PartialEq + Zero,
{
    /// Adds an edge between two vertices.
    ///
    /// # Returns
    /// * `Ok(true)` - Edge was added
    /// * `Ok(false)` - Edge already existed
    /// * `Err(TopologyError)` - If vertices are out of bounds
    pub fn add_edge(&mut self, u: usize, v: usize) -> Result<bool, TopologyError> {
        self.add_edge_impl(u, v)
    }

    /// Checks if an edge exists between two vertices.
    pub fn has_edge(&self, u: usize, v: usize) -> Result<bool, TopologyError> {
        self.has_edge_impl(u, v)
    }

    /// Returns a reference to the neighbors of a given vertex.
    pub fn neighbors(&self, u: usize) -> Result<&Vec<usize>, TopologyError> {
        self.neighbors_impl(u)
    }

    /// Returns the current cursor position.
    pub fn cursor(&self) -> usize {
        self.cursor
    }
}
