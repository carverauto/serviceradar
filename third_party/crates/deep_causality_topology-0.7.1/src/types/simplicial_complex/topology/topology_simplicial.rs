/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Simplex, SimplicialComplex, SimplicialTopology, TopologyError};
impl<T> SimplicialTopology for SimplicialComplex<T> {
    fn max_simplex_dimension(&self) -> usize {
        self.skeletons.iter().map(|s| s.dim).max().unwrap_or(0)
    }

    fn num_simplices_at_grade(&self, grade: usize) -> Result<usize, TopologyError> {
        self.skeletons
            .iter()
            .find(|s| s.dim == grade)
            .map(|s| s.simplices.len())
            .ok_or_else(|| {
                TopologyError::DimensionMismatch(format!("No skeleton found for grade {}", grade))
            })
    }

    fn get_simplex(&self, grade: usize, index: usize) -> Result<&Simplex, TopologyError> {
        let skeleton = self
            .skeletons
            .iter()
            .find(|s| s.dim == grade)
            .ok_or_else(|| {
                TopologyError::DimensionMismatch(format!("No skeleton found for grade {}", grade))
            })?;

        skeleton.simplices.get(index).ok_or_else(|| {
            TopologyError::IndexOutOfBounds(format!(
                "Simplex index {} out of bounds for grade {}",
                index, grade
            ))
        })
    }

    fn contains_simplex(&self, simplex: &Simplex) -> bool {
        let dim = if simplex.vertices.is_empty() {
            return false;
        } else {
            simplex.vertices.len() - 1
        };

        if let Some(skeleton) = self.skeletons.iter().find(|s| s.dim == dim) {
            skeleton.get_index(simplex).is_some()
        } else {
            false
        }
    }
}
