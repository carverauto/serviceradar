/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod adjustable;
mod coordinate;
mod display;
mod getters;
mod identifiable;
mod space_temporal;
mod space_temporal_interval;
mod spatial;
mod temporal;

use crate::TimeScale;

/// A 4-dimensional spacetime context based on Lorentzian geometry, as used in General Relativity.
///
/// `LorentzianSpacetime` encodes events in a curved or flat spacetime using the
/// **Minkowski metric signature** (−+++). This allows meaningful distinction between
/// **time-like**, **space-like**, and **light-like** intervals:
///
/// - `s² < 0`: time-like separation
/// - `s² = 0`: light-like (null) separation
/// - `s² > 0`: space-like separation
///
/// The default implementation assumes flat spacetime (no curvature), suitable for special relativity.
/// For curved general relativistic spacetime, a metric tensor can be added later.
///
/// # Fields
/// - `id`: Unique numeric identifier
/// - `x`: X-coordinate in meters
/// - `y`: Y-coordinate in meters
/// - `z`: Z-coordinate in meters
/// - `t`: time (e.g., seconds)
/// - `time_scale`: Time scale unit (e.g., seconds, milliseconds)
///
/// # Coordinate Index Mapping
/// /// When used with the `Coordinate` trait, the following index mapping applies:
/// - `0 => x`
/// - `1 => y`
/// - `2 => z`
/// - `3 => t`
///
/// # Minkowski interval (squared):
/// ```text
/// s² = -c²·t² + x² + y² + z²
/// ```
///
/// # Notes
/// - The time coordinate is not just a timestamp — it has physical meaning (e.g., proper time)
/// - The sign convention is configurable (−+++) or (+−−−), but we assume (−+++) by default
/// - Units must be consistent (e.g., all in SI)
///
/// # Example
/// ```
/// use deep_causality::*;
///
/// let s1 = LorentzianSpacetime::new(1, 1.0, 0.0, 0.0, 0.0, TimeScale::Second);
/// let s2 = LorentzianSpacetime::new(2, 2.0, 3.0, 4.0, 0.0, TimeScale::Second);
///
/// let interval = s1.interval_squared(&s2);
/// println!("Minkowski interval²: {interval}");
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct LorentzianSpacetime {
    id: u64,
    x: f64, // space in meters
    y: f64,
    z: f64,
    t: f64,                // time in SI time unit
    time_scale: TimeScale, // SI time unit
}

impl LorentzianSpacetime {
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
