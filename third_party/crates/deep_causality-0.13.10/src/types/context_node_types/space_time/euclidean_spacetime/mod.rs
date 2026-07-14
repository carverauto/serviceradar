/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod adjustable;
mod coordinate;
mod display;
mod getters;
mod identifiable;
mod metric;
mod space_temporal;
mod spatial;
mod temporal;

use crate::TimeScale;

/// A concrete 3D + time context based on classical (Euclidean) geometry.
///
/// `EuclideanSpacetime` models a spatial point in 3D Euclidean space with an
/// associated monotonic time unit (e.g., nanoseconds, milliseconds). This is
/// the default representation for causal modeling in low-latency engineering
/// systems such as sensor fusion, MagNav, or robotics.
///
/// The space is assumed to be flat and orthogonal (Cartesian), and time is
/// treated as an absolute scalar clock.
///
/// # Fields
/// - `id`: Unique numeric identifier
/// - `x`: X-coordinate in meters
/// - `y`: Y-coordinate in meters
/// - `z`: Z-coordinate in meters
/// - `t`: time (e.g., seconds)
/// - `time_scale`: Time scale unit (e.g., microseconds, milliseconds)
///
/// # Coordinate Index Mapping
/// When used with the `Coordinate` trait, the following index mapping applies:
/// - `0 => x`
/// - `1 => y`
/// - `2 => z`
/// - `3 => t`
///
/// # Common Applications
/// - Sensor placement and motion modeling
/// - Low-latency messaging with time-stamped spatial tags
/// - Aircraft, drone, or embedded system causal modeling
///
/// # Example
/// ```
/// use deep_causality::*;
///
/// let s1 = EuclideanSpacetime::new(1, 0.0, 0.0, 0.0, 1_000_000.00f64, TimeScale::Second);
/// let s2 = EuclideanSpacetime::new(2, 3.0, 4.0, 0.0, 2_000_000.00f64, TimeScale::Second);
///
/// let spatial_dist = s1.distance(&s2); // should be 5.0
/// println!("Distance: {:.2} meters", spatial_dist);
/// assert_eq!(s1.dimension(), 4);
/// assert_eq!(s2.coordinate(0).unwrap(), &3.0);
/// ```
#[derive(Debug, Copy, Clone, PartialEq)]
pub struct EuclideanSpacetime {
    /// Unique numeric ID for this context
    id: u64,
    /// Spatial coordinates in `[x, y, z]` (meters)
    x: f64,
    y: f64,
    z: f64,
    /// Scalar time value (e.g., nanoseconds since epoch)
    t: f64, // time in SI time unit
    /// Time unit scale (used for interpretation, not math)
    time_scale: TimeScale,
}

impl EuclideanSpacetime {
    pub fn new(id: u64, x: f64, y: f64, z: f64, t: f64, time_scale: TimeScale) -> Self {
        Self {
            id,
            x,
            y,
            z,
            t,
            time_scale,
        }
    }
}
