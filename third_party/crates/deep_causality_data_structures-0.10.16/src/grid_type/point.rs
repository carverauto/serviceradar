/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt;

/// Enumeration representing the dimensionality of a `PointIndex`.
///
/// Used internally to determine how to format and interpret the index:
/// - `OneD`: Only the X dimension is used.
/// - `TwoD`: X and Y dimensions are used.
/// - `ThreeD`: X, Y, and Z dimensions are used.
/// - `FourD`: X, Y, Z, and T (time) dimensions are used.
#[derive(Debug, Clone, Copy)]
#[repr(u8)]
pub enum PointIndexType {
    OneD = 0,
    TwoD = 1,
    ThreeD = 2,
    FourD = 3,
}

/// A generic, strongly-typed point index for addressing elements
/// in up to four-dimensional grid-based storage structures.
///
/// Each instance tracks not just the coordinate values but also
/// the type of index (1D–4D) to support safe formatting and introspection.
#[derive(Debug, Clone, Copy)]
pub struct PointIndex {
    pub x: usize,
    // Height
    pub y: usize,
    // Width
    pub z: usize,
    // Depth
    pub t: usize, // Time
    point_type: PointIndexType,
}

impl PointIndex {
    /// Creates a 1D index with the given `x` coordinate.
    ///
    /// All other coordinates default to 0.
    pub fn new1d(x: usize) -> Self {
        Self {
            x,
            y: 0,
            z: 0,
            t: 0,
            point_type: PointIndexType::OneD,
        }
    }

    /// Creates a 2D index with the given `x` and `y` coordinates.
    ///
    /// `z` and `t` default to 0.
    pub fn new2d(x: usize, y: usize) -> Self {
        Self {
            x,
            y,
            z: 0,
            t: 0,
            point_type: PointIndexType::TwoD,
        }
    }

    /// Creates a 3D index with the given `x`, `y`, and `z` coordinates.
    ///
    /// `t` defaults to 0.
    pub fn new3d(x: usize, y: usize, z: usize) -> Self {
        Self {
            x,
            y,
            z,
            t: 0,
            point_type: PointIndexType::ThreeD,
        }
    }

    /// Creates a 4D index with the given `x`, `y`, `z`, and `t` coordinates.
    pub fn new4d(x: usize, y: usize, z: usize, t: usize) -> Self {
        Self {
            x,
            y,
            z,
            t,
            point_type: PointIndexType::FourD,
        }
    }

    /// Returns the type of point index (1D, 2D, 3D, or 4D)
    pub fn point_type(&self) -> PointIndexType {
        self.point_type
    }
}

/// Provides a human-readable string representation of the index,
/// varying based on its dimensional type.
///
/// Examples:
/// - 1D: `(x:3)`
/// - 2D: `(x:3, y:2)`
/// - 3D: `(x:3, y:2, z:1)`
/// - 4D: `(x:3, y:2, z:1, t:0)`
impl fmt::Display for PointIndex {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.point_type {
            PointIndexType::OneD => write!(f, "(x:{})", self.x),
            PointIndexType::TwoD => write!(f, "(x:{}, y:{})", self.x, self.y),
            PointIndexType::ThreeD => write!(f, "(x:{}, y:{}, z:{})", self.x, self.y, self.z),
            PointIndexType::FourD => write!(
                f,
                "(x:{}, y:{}, z:{}, t:{})",
                self.x, self.y, self.z, self.t
            ),
        }
    }
}
