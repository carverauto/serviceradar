/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{BaseTopology, SimplicialComplex};

impl<T> BaseTopology for SimplicialComplex<T> {
    fn dimension(&self) -> usize {
        self.skeletons.last().map(|s| s.dim).unwrap_or(0)
    }

    fn len(&self) -> usize {
        self.skeletons.iter().map(|s| s.simplices.len()).sum()
    }

    fn num_elements_at_grade(&self, grade: usize) -> Option<usize> {
        self.skeletons
            .iter()
            .find(|s| s.dim == grade)
            .map(|s| s.simplices.len())
    }
}
