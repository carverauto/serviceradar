/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{BaseTopology, Manifold, SimplicialComplex};

impl<C: deep_causality_algebra::RealField, D> BaseTopology for Manifold<SimplicialComplex<C>, D> {
    fn dimension(&self) -> usize {
        // The dimension of the complex is the dimension of the highest-dimensional skeleton.
        // We assume skeletons are ordered by dimension.
        self.complex.skeletons.last().map(|s| s.dim).unwrap_or(0)
    }

    fn len(&self) -> usize {
        // Total number of simplices across all dimensions.
        self.complex
            .skeletons
            .iter()
            .map(|s| s.simplices.len())
            .sum()
    }

    fn num_elements_at_grade(&self, grade: usize) -> Option<usize> {
        // We assume skeletons[grade] corresponds to the skeleton of that dimension.
        self.complex
            .skeletons
            .iter()
            .find(|s| s.dim == grade)
            .map(|s| s.simplices.len())
    }
}
