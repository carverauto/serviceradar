/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of PointCloud constructors.

use crate::{PointCloud, TopologyError};
use deep_causality_num::Zero;
use deep_causality_tensor::CausalTensor;

impl<C, D> PointCloud<C, D> {
    /// CPU implementation of PointCloud constructor.
    pub(crate) fn new_impl(
        points: CausalTensor<C>,
        metadata: CausalTensor<D>,
        cursor: usize,
    ) -> Result<Self, TopologyError>
    where
        C: Default + Copy + Clone + PartialEq + Zero,
        D: Default + Copy + Clone + PartialEq + Zero,
    {
        if points.is_empty() || points.shape().is_empty() {
            return Err(TopologyError::InvalidInput(
                "PointCloud `points` cannot be empty or have invalid shape".to_string(),
            ));
        }
        if points.shape()[0] != metadata.shape()[0] {
            return Err(TopologyError::InvalidInput(
                "Number of points and metadata items must match".to_string(),
            ));
        }
        if cursor >= points.len() {
            return Err(TopologyError::IndexOutOfBounds(
                "Initial cursor out of bounds for PointCloud".to_string(),
            ));
        }

        Ok(Self {
            points,
            metadata,
            cursor,
        })
    }

    /// Creates a shallow clone of the PointCloud.
    pub fn clone_shallow(&self) -> Self
    where
        C: Clone,
        D: Clone,
    {
        PointCloud {
            points: self.points.clone(),
            metadata: self.metadata.clone(),
            cursor: 0,
        }
    }
}
