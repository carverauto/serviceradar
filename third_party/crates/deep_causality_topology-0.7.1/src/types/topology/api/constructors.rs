/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Constructor API for Topology.

use crate::{SimplicialComplex, Topology, TopologyError};
use deep_causality_tensor::CausalTensor;
use std::sync::Arc;

impl<T> Topology<T> {
    /// Creates a new Topology field on a k-skeleton.
    ///
    /// # Arguments
    /// * `complex` - Reference to the underlying mesh
    /// * `grade` - Dimension of simplices the data lives on
    /// * `data` - Field values
    /// * `cursor` - Initial cursor position
    ///
    /// # Returns
    /// * `Ok(Topology)` - A valid topology field
    /// * `Err(TopologyError)` - If validation fails
    pub fn new(
        complex: Arc<SimplicialComplex<T>>,
        grade: usize,
        data: CausalTensor<T>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        Self::new_impl(complex, grade, data, cursor)
    }
}
