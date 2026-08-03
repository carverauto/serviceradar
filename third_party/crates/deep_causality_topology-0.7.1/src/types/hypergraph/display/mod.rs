/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Display implementations for Hypergraph.

use crate::Hypergraph;
use core::fmt;

impl<T> fmt::Display for Hypergraph<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Hypergraph {{ nodes: {}, hyperedges: {} }}",
            self.num_nodes, self.num_hyperedges
        )
    }
}
