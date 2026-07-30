/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of Topology constructors.

use crate::{SimplicialComplex, Topology, TopologyError};
use deep_causality_tensor::CausalTensor;
use std::sync::Arc;

impl<T> Topology<T> {
    /// CPU implementation of Topology constructor.
    pub(crate) fn new_impl(
        complex: Arc<SimplicialComplex<T>>,
        grade: usize,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        // Validate grade
        if grade > complex.max_simplex_dimension() {
            return Err(TopologyError::InvalidGradeOperation(format!(
                "grade {} exceeds max dimension {}",
                grade,
                complex.max_simplex_dimension()
            )));
        }

        if grade >= complex.skeletons.len() {
            return Err(TopologyError::InvalidInput(format!(
                "grade {} exceeds available skeletons {}",
                grade,
                complex.skeletons.len()
            )));
        }

        let expected_size = complex.skeletons[grade].simplices.len();
        if data.len() != expected_size {
            return Err(TopologyError::InvalidInput(format!(
                "data length {} does not match skeleton size {} for grade {}",
                data.len(),
                expected_size,
                grade
            )));
        }

        if cursor >= data.len() && !data.is_empty() {
            return Err(TopologyError::IndexOutOfBounds(format!(
                "cursor {} is out of bounds for data length {}",
                cursor,
                data.len()
            )));
        }

        Ok(Self {
            complex,
            grade,
            data,
            cursor,
        })
    }
}
