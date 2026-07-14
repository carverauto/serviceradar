/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::IndexError;

/// Provides a generalized interface for N-dimensional coordinate access.
///
/// This trait is agnostic to geometry and is designed to support
/// both standard (Cartesian) coordinates and abstract representations such as:
/// - Curved spacetime manifolds
/// - Quaternionic rotations
/// - Symbolic embeddings (e.g., logical coordinates)
///
/// The trait provides only **index-based access** and leaves axis naming,
/// scaling, or metric behavior to higher-level abstractions.
///
/// # Example
/// ```
/// use deep_causality::{Coordinate, IndexError};
///
/// struct Vec3D {
///     x: f64,
///     y: f64,
///     z: f64,
/// }
///
/// impl Coordinate<f64> for Vec3D {
///     fn dimension(&self) -> usize {
///         3
///     }
///
///      fn coordinate(&self, index: usize) -> Result<&f64, IndexError> {
///         match index {
///             0 => Ok(&self.x),
///             1 => Ok(&self.y),
///             2 => Ok(&self.z),
///             _ => Err(IndexError("Index out of bounds".to_string())),
///         }
///     }
/// }
/// ```
pub trait Coordinate<V> {
    /// Returns the number of dimensions defined in this coordinate system.
    fn dimension(&self) -> usize;

    /// Returns a reference to the value at a given axis index (0-based).
    ///
    /// # Errors
    /// Returns `IndexError` if the index is out of bounds.
    fn coordinate(&self, index: usize) -> Result<&V, IndexError>;
}
