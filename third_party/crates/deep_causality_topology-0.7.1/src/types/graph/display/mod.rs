/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Display implementations for Graph.

use crate::Graph;
use core::fmt;

impl<T> fmt::Display for Graph<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Graph {{ vertices: {}, edges: {} }}",
            self.num_vertices, self.num_edges
        )
    }
}
