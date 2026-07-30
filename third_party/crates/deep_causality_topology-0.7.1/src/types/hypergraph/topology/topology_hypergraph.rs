/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Hypergraph, HypergraphTopology, TopologyError};

impl<T> HypergraphTopology for Hypergraph<T> {
    fn num_hyperedges(&self) -> usize {
        self.num_hyperedges
    }

    fn nodes_in_hyperedge(&self, hyperedge_id: usize) -> Result<Vec<usize>, TopologyError> {
        if hyperedge_id >= self.num_hyperedges {
            return Err(TopologyError::HypergraphError(format!(
                "Hyperedge index {} out of bounds (max {})",
                hyperedge_id,
                self.num_hyperedges - 1
            )));
        }

        let mut nodes = Vec::new();
        // The incidence matrix is (nodes x hyperedges), so we need to iterate
        // through the column corresponding to the hyperedge.
        // This is not directly efficient with CsrMatrix, which is row-major.
        for node_idx in 0..self.num_nodes {
            let row_start = self.incidence.row_indices()[node_idx];
            let row_end = self.incidence.row_indices()[node_idx + 1];

            for i in row_start..row_end {
                if self.incidence.col_indices()[i] == hyperedge_id
                    && self.incidence.values()[i] == 1
                {
                    nodes.push(node_idx);
                    break;
                }
            }
        }
        Ok(nodes)
    }

    fn hyperedges_on_node(&self, node_id: usize) -> Result<Vec<usize>, TopologyError> {
        if node_id >= self.num_nodes {
            return Err(TopologyError::HypergraphError(format!(
                "Node index {} out of bounds (max {})",
                node_id,
                self.num_nodes - 1
            )));
        }

        let mut hyperedges = Vec::new();
        let row_start = self.incidence.row_indices()[node_id];
        let row_end = self.incidence.row_indices()[node_id + 1];

        for i in row_start..row_end {
            if self.incidence.values()[i] == 1 {
                hyperedges.push(self.incidence.col_indices()[i]);
            }
        }

        Ok(hyperedges)
    }
}
