/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{BaseTopology, Graph};

impl<T> BaseTopology for Graph<T> {
    fn dimension(&self) -> usize {
        // Graph is a 1-complex (vertices and edges)
        1
    }

    fn len(&self) -> usize {
        // Primary elements are vertices
        self.num_vertices
    }

    fn num_elements_at_grade(&self, grade: usize) -> Option<usize> {
        match grade {
            0 => Some(self.num_vertices),
            1 => Some(self.num_edges),
            _ => None,
        }
    }
}
