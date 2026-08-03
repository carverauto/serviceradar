/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GraphTopology, MixedGraph, TopologyError};

impl<T> GraphTopology for MixedGraph<T> {
    fn num_nodes(&self) -> usize {
        self.num_vertices
    }

    fn num_edges(&self) -> usize {
        self.edges.len()
    }

    fn has_node(&self, node_id: usize) -> bool {
        node_id < self.num_vertices
    }

    /// Neighbors span every edge kind: any node sharing an edge with `node_id`.
    fn get_neighbors(&self, node_id: usize) -> Result<Vec<usize>, TopologyError> {
        self.check_node(node_id)?;

        let mut neighbors: Vec<usize> = self
            .edges
            .keys()
            .filter_map(|&(a, b)| {
                if a == node_id {
                    Some(b)
                } else if b == node_id {
                    Some(a)
                } else {
                    None
                }
            })
            .collect();
        neighbors.sort_unstable();
        Ok(neighbors)
    }
}
