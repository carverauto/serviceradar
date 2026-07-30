/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Getter methods for PointCloud.

use crate::PointCloud;
use deep_causality_tensor::CausalTensor;

impl<C, D> PointCloud<C, D> {
    pub fn points(&self) -> &CausalTensor<C> {
        &self.points
    }

    pub fn metadata(&self) -> &CausalTensor<D> {
        &self.metadata
    }
}
