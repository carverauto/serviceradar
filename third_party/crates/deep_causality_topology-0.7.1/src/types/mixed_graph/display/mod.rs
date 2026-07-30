/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Display implementation for MixedGraph.

use crate::MixedGraph;
use core::fmt;

impl<T> fmt::Display for MixedGraph<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "MixedGraph {{ vertices: {}, edges: {} }}",
            self.num_vertices,
            self.edges.len()
        )
    }
}
