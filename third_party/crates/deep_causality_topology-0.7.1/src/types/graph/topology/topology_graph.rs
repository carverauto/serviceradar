/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Graph, GraphTopology, TopologyError};

impl<T> GraphTopology for Graph<T> {
    fn num_nodes(&self) -> usize {
        self.num_vertices
    }

    fn num_edges(&self) -> usize {
        self.num_edges
    }

    fn has_node(&self, node_id: usize) -> bool {
        node_id < self.num_vertices
    }

    fn get_neighbors(&self, node_id: usize) -> Result<Vec<usize>, TopologyError> {
        if node_id >= self.num_vertices {
            return Err(TopologyError::GraphError(format!(
                "Node index {} out of bounds (max {})",
                node_id,
                self.num_vertices - 1
            )));
        }

        Ok(self.adjacencies.get(&node_id).unwrap().clone())
    }
}
