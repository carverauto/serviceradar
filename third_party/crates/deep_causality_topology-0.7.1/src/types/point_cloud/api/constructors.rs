/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Constructor API for PointCloud.

use crate::{PointCloud, TopologyError};
use deep_causality_num::Zero;
use deep_causality_tensor::CausalTensor;

impl<C, D> PointCloud<C, D> {
    /// Creates a new `PointCloud` from points and metadata tensors.
    ///
    /// # Arguments
    /// * `points` - Tensor of NxM (N points in M dimensions)
    /// * `metadata` - Tensor of N metadata items
    /// * `cursor` - Initial cursor position
    ///
    /// # Returns
    /// * `Ok(PointCloud)` - A valid point cloud
    /// * `Err(TopologyError)` - If validation fails
    pub fn new(
        points: CausalTensor<C>,
        metadata: CausalTensor<D>,
        cursor: usize,
    ) -> Result<Self, TopologyError>
    where
        C: Default + Copy + Clone + PartialEq + Zero,
        D: Default + Copy + Clone + PartialEq + Zero,
    {
        Self::new_impl(points, metadata, cursor)
    }
}
