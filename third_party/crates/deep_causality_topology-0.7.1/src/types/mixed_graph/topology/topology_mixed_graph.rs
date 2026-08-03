/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{EdgeKind, MixedGraph, MixedGraphTopology, TopologyError};

impl<T> MixedGraphTopology for MixedGraph<T> {
    fn num_arcs(&self) -> usize {
        self.count_of_kind(EdgeKind::Directed)
    }

    fn num_undirected_edges(&self) -> usize {
        self.count_of_kind(EdgeKind::Undirected)
    }

    fn get_parents(&self, node_id: usize) -> Result<Vec<usize>, TopologyError> {
        self.check_node(node_id)?;
        Ok(self.parents(node_id))
    }

    fn get_undirected_neighbors(&self, node_id: usize) -> Result<Vec<usize>, TopologyError> {
        self.check_node(node_id)?;
        Ok(self.undirected_neighbors(node_id))
    }
}
