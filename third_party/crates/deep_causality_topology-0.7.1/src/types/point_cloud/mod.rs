/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! PointCloud type for representing point collections.

use deep_causality_tensor::CausalTensor;

// Submodule declarations (folder-based)
mod api;
mod constructors;
mod display;
mod getters;

mod ops;
mod topology;

// Re-export public API

/// Represents a collection of data points in a d-dimensional space.
///
/// This is a "0-Complex" that can be used to infer higher-order topological structures.
#[derive(Debug, Clone, PartialEq)]
pub struct PointCloud<C, D> {
    /// The coordinates of the points. Typically NxM for N points in M dimensions.
    pub(crate) points: CausalTensor<C>,
    /// Optional metadata associated with each point.
    pub(crate) metadata: CausalTensor<D>,
    /// The Focus (Cursor) for Comonadic extraction.
    pub(crate) cursor: usize,
}

impl<C, D> PointCloud<C, D> {
    /// Returns the number of points in the cloud.
    pub fn len(&self) -> usize {
        self.points.shape()[0]
    }

    /// Returns true if the point cloud contains no points.
    pub fn is_empty(&self) -> bool {
        self.points.is_empty()
    }

    /// Returns the current cursor position.
    pub fn cursor(&self) -> usize {
        self.cursor
    }
}
