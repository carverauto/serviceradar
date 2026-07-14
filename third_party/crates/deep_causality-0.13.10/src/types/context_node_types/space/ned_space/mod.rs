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
mod spatial;

/// A local tangent-plane spatial context using the North-East-Down (NED) reference frame.
///
/// `NedSpace` represents a point in a locally linearized coordinate system centered at a reference
/// geodetic location (typically defined by a GPS fix). It is commonly used in aerospace,
/// robotics, and real-time navigation systems to express motion and sensor positions
/// relative to a local Earth-aligned frame.
///
/// This frame uses the following axis definitions:
/// - **North (+N)**: tangential to the Earth's surface, pointing toward the North Pole
/// - **East (+E)**: tangential to the Earth's surface, perpendicular to North, pointing eastward
/// - **Down (+D)**: aligned with gravity, pointing toward the Earth's center (positive downward)
///
/// This results in a **right-handed coordinate system** with the origin at a defined reference point,
/// and the frame fixed to the Earth — making it suitable for integrating IMUs, magnetometers, and
/// other aircraft-attached sensors.
///
/// # Fields
/// - `id`: Unique numeric identifier for this NED spatial context (e.g., sensor ID)
/// - `north`: Position in meters along the northward axis
/// - `east`: Position in meters along the eastward axis
/// - `down`: Position in meters along the downward (gravity-aligned) axis
///
/// # Coordinate Index Mapping
/// When used with the `Coordinate` trait, the following index mapping applies:
/// - `0 => north`
/// - `1 => east`
/// - `2 => down`
///
/// # Common Applications
/// - Aircraft position estimation relative to a flight segment origin
/// - Magnetometer placement in local frame for MagNav systems
/// - Inertial Navigation System (INS) drift correction
/// - Real-time sensor fusion in autonomous drones or ground vehicles
///
/// # Example
/// ```
/// use deep_causality::*;
///
/// let n1 = NedSpace::new(1, 0.0, 0.0, 0.0);      // Reference origin
/// let n2 = NedSpace::new(2, 100.0, 50.0, 10.0);  // 100m North, 50m East, 10m below origin
///
/// println!("{}", n2);
///
/// assert_eq!(n2.dimension(), 3);
/// assert_eq!(n1.distance(&n2), (100.0_f64.powi(2) + 50.0_f64.powi(2) + 10.0_f64.powi(2)).sqrt());
/// ```
///
/// # Notes
/// - The "down" axis is **positive in the direction of gravity**. This is a key difference
///   from ENU (East-North-Up) or typical 3D Cartesian conventions.
/// - This struct assumes **flat-Earth approximation** — for global modeling, use `GeoSpace` or `EcefSpace`.
#[derive(Debug, Clone, PartialEq)]
pub struct NedSpace {
    /// Unique numeric ID for this local NED context
    id: u64,
    /// Distance north from the reference point (in meters)
    north: f64,
    /// Distance east from the reference point (in meters)
    east: f64,
    /// Vertical distance down from the reference point (in meters, positive = downward)
    down: f64,
}

impl NedSpace {
    pub fn new(id: u64, north: f64, east: f64, down: f64) -> Self {
        Self {
            id,
            north,
            east,
            down,
        }
    }
}
