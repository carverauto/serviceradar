/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// Grids in Rust, part 2: const generics
// https://blog.adamchalmers.com/grids-2/#benchmarks-1d-vs-2d-vec-vs-array

// Storage API:
// Single entry type Grid which is generic over its storage and implements for all traits.
// - Only expose a minimal subset to interact with the grid over the storage API
// - Implementing new storage types is a lot easier.
// - The disparity between different representations and what they implement is removed.
// https://github.com/petgraph/petgraph/issues/563

use crate::PointIndex;

/// A generic trait for accessing and mutating multi-dimensional storage containers
/// such as 1D, 2D, 3D, and 4D arrays using `PointIndex`.
///
/// This trait provides a common interface to:
/// - retrieve elements via `get`
/// - modify elements via `set`
/// - introspect the array dimensions if known at compile time.
///
/// The storage is assumed to be indexed using a `PointIndex`, whose fields
/// `x`, `y`, `z`, and `t` map to dimensions like width, height, depth, and time.
pub trait Storage<T>
where
    T: Copy,
{
    /// Retrieves an immutable reference to the element at the specified point.
    ///
    /// # Panics
    /// Panics if the index is out of bounds for the storage container.
    fn get(&self, p: PointIndex) -> &T;

    /// Sets the element at the specified point to the given value.
    ///
    /// # Panics
    /// Panics if the index is out of bounds for the storage container.
    fn set(&mut self, p: PointIndex, elem: T);

    /// Returns the height (Y-axis) dimension of the storage, if defined.
    fn height(&self) -> Option<&usize>;

    /// Returns the depth (Z-axis) dimension of the storage, if defined.
    fn depth(&self) -> Option<&usize> {
        None
    }

    /// Returns the time (T-axis) dimension of the storage, if defined.
    fn time(&self) -> Option<&usize> {
        None
    }

    /// Returns the width (X-axis) dimension of the storage, if defined.
    fn width(&self) -> Option<&usize> {
        None
    }
}
