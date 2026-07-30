/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GraphTopology, Hypergraph, TopologyError};
use std::collections::BTreeSet;

impl<T> GraphTopology for Hypergraph<T> {
    fn num_nodes(&self) -> usize {
        self.num_nodes
    }

    fn num_edges(&self) -> usize {
        // In a hypergraph, we treat hyperedges as generalized edges
        self.num_hyperedges
    }

    fn has_node(&self, node_id: usize) -> bool {
        node_id < self.num_nodes
    }

    fn get_neighbors(&self, node_id: usize) -> Result<Vec<usize>, TopologyError> {
        if node_id >= self.num_nodes {
            return Err(TopologyError::HypergraphError(format!(
                "Node index {} out of bounds (max {})",
                node_id,
                self.num_nodes - 1
            )));
        }

        // Find all hyperedges containing this node
        let mut neighbors = BTreeSet::new();

        // Get the row for this node
        let row_start = self.incidence.row_indices()[node_id];
        let row_end = self.incidence.row_indices()[node_id + 1];

        // For each hyperedge this node belongs to
        for i in row_start..row_end {
            if self.incidence.values()[i] == 1 {
                let hyperedge_idx = self.incidence.col_indices()[i];

                // Find all other nodes in this hyperedge
                for other_node in 0..self.num_nodes {
                    if other_node != node_id {
                        let other_row_start = self.incidence.row_indices()[other_node];
                        let other_row_end = self.incidence.row_indices()[other_node + 1];

                        for j in other_row_start..other_row_end {
                            if self.incidence.col_indices()[j] == hyperedge_idx
                                && self.incidence.values()[j] == 1
                            {
                                neighbors.insert(other_node);
                            }
                        }
                    }
                }
            }
        }

        Ok(neighbors.into_iter().collect())
    }
}
