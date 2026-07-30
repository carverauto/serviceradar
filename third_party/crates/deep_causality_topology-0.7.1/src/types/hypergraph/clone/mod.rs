/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Clone implementations for Hypergraph.

use crate::Hypergraph;

impl<T> Hypergraph<T> {
    /// Creates a shallow clone of the Hypergraph.
    pub fn clone_shallow(&self) -> Self
    where
        T: Clone,
    {
        Hypergraph {
            num_nodes: self.num_nodes,
            num_hyperedges: self.num_hyperedges,
            incidence: self.incidence.clone(),
            data: self.data.clone(),
            cursor: 0,
        }
    }
}
