/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt::Debug;

mod adjustable;
mod coordinate;
mod display;
mod getters;
mod identifiable;
mod metric;
mod spatial;

/// A 3-dimensional spatial context represented in standard Euclidean coordinates (x, y, z).
///
/// This struct is used as the default implementation of a purely spatial context
/// in the DeepCausality framework. It supports coordinate access and distance
/// measurement based on Euclidean geometry.
///
/// # Fields
/// - `id`: A unique identifier for this spatial entity
/// - `x`: X-coordinate in meters
/// - `y`: Y-coordinate in meters
/// - `z`: Z-coordinate in meters
///
/// # Coordinate Index Mapping
/// When used with the `Coordinate` trait, the following index mapping applies:
/// - `0 => x`
/// - `1 => y`
/// - `2 => z`
///
/// # Examples
/// ```
/// use deep_causality::*;
///
/// let space_a = EuclideanSpace::new(1, 1.0, 2.0, 3.0);
/// let space_b = EuclideanSpace::new(2, 4.0, 6.0, 3.0);
///
/// assert_eq!(space_a.dimension(), 3);
/// assert_eq!(space_a.coordinate(1).unwrap(), &2.0);
/// assert_eq!(space_a.distance(&space_b), 5.0);
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct EuclideanSpace {
    id: u64,
    x: f64,
    y: f64,
    z: f64,
}

impl EuclideanSpace {
    pub fn new(id: u64, x: f64, y: f64, z: f64) -> Self {
        Self { id, x, y, z }
    }
}
