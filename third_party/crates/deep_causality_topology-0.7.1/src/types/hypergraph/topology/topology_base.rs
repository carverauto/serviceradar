/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{BaseTopology, Hypergraph};

impl<T> BaseTopology for Hypergraph<T> {
    fn dimension(&self) -> usize {
        // Hypergraph is conceptually a 1-complex (nodes and hyperedges)
        1
    }

    fn len(&self) -> usize {
        // Primary elements are nodes
        self.num_nodes
    }

    fn num_elements_at_grade(&self, grade: usize) -> Option<usize> {
        match grade {
            0 => Some(self.num_nodes),
            1 => Some(self.num_hyperedges),
            _ => None,
        }
    }
}
