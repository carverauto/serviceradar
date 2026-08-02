/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of Graph operations.

use crate::{Graph, TopologyError};
use deep_causality_num::Zero;
impl<T> Graph<T>
where
    T: Default + Copy + Clone + PartialEq + Zero,
{
    /// CPU implementation of add_edge.
    pub(crate) fn add_edge_impl(&mut self, u: usize, v: usize) -> Result<bool, TopologyError> {
        if u >= self.num_vertices || v >= self.num_vertices {
            return Err(TopologyError::GraphError(format!(
                "Vertex index out of bounds: num_vertices={}, u={}, v={}",
                self.num_vertices, u, v
            )));
        }

        if u == v {
            return Err(TopologyError::GraphError(
                "Self-loops are not allowed in this graph implementation".to_string(),
            ));
        }

        let u_neighbors = self.adjacencies.get_mut(&u).unwrap();
        if !u_neighbors.contains(&v) {
            u_neighbors.push(v);
            u_neighbors.sort_unstable();
            self.num_edges += 1;

            let v_neighbors = self.adjacencies.get_mut(&v).unwrap();
            v_neighbors.push(u);
            v_neighbors.sort_unstable();
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// CPU implementation of has_edge.
    pub(crate) fn has_edge_impl(&self, u: usize, v: usize) -> Result<bool, TopologyError> {
        if u >= self.num_vertices || v >= self.num_vertices {
            return Err(TopologyError::GraphError(format!(
                "Vertex index out of bounds: num_vertices={}, u={}, v={}",
                self.num_vertices, u, v
            )));
        }
        Ok(self
            .adjacencies
            .get(&u)
            .is_some_and(|neighbors| neighbors.contains(&v)))
    }

    /// CPU implementation of neighbors.
    pub(crate) fn neighbors_impl(&self, u: usize) -> Result<&Vec<usize>, TopologyError> {
        if u >= self.num_vertices {
            return Err(TopologyError::GraphError(format!(
                "Vertex index out of bounds: num_vertices={}, u={}",
                self.num_vertices, u
            )));
        }
        Ok(self.adjacencies.get(&u).unwrap())
    }
}
