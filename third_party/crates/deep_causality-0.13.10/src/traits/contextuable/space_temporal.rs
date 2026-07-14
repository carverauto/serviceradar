/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Identifiable;
use crate::traits::contextuable::spatial::Spatial;
use crate::traits::contextuable::temporal::Temporal;

/// Combines spatial and temporal semantics into a 4D spacetime model.
///
/// This is ideal for modeling causal entities that exist at a particular
/// **spatial location** and **point in time**. The `t()` method supplements
/// the coordinate system with a direct accessor for the temporal axis.
///
/// This trait enables compatibility with:
/// - Newtonian and Einsteinian physics
/// - Sensor frames
/// - 4D event graphs
///
/// # Note
/// The actual meaning of `t()` depends on the context—e.g., wall clock time,
/// simulation ticks, or a relativistic coordinate frame.
pub trait SpaceTemporal<VS, VT>: Identifiable + Spatial<VS> + Temporal<VT> {
    /// Returns the value associated with the temporal (4th) dimension.
    fn t(&self) -> &VT;
}

/// Trait for spacetime types that support Minkowski-style interval calculations.
///
/// This trait enables causal reasoning in spacetime-aware systems using the Minkowski
/// metric from special relativity:
///
/// ```text
/// s² = -c²·Δt² + Δx² + Δy² + Δz²
/// ```
///
/// This interval:
/// - Is negative for **time-like** separations (causally connected)
/// - Is zero for **light-like** (null) paths (on the light cone)
/// - Is positive for **space-like** separations (no causal connection)
///
/// The default implementation assumes:
/// - Time is in **seconds**
/// - Space is in **meters**
/// - Speed of light `c = 299_792_458 m/s`
///
/// # Required Methods
/// - `time()`: Returns the scalar time coordinate in seconds
/// - `position()`: Returns the spatial coordinates `[x, y, z]` in meters
///
/// # Default Method
/// - `interval_squared(&self, &Self) -> f64`: Computes the squared interval between two events
///
pub trait SpaceTemporalInterval {
    /// Returns the time coordinate in **seconds**.
    fn time(&self) -> f64;

    /// Returns the spatial coordinates `[x, y, z]` in **meters**.
    fn position(&self) -> [f64; 3];

    /// Computes the squared Minkowski interval between `self` and `other`.
    ///
    /// ```text
    /// s² = -c²·Δt² + Δx² + Δy² + Δz²
    /// ```
    /// where `c = 299_792_458 m/s`.
    ///
    /// Negative `s²` indicates time-like separation,
    /// zero indicates light-like (null),
    /// and positive indicates space-like.
    fn interval_squared(&self, other: &Self) -> f64 {
        let c = 299_792_458.0; // Speed of light (m/s)

        let dt = self.time() - other.time();
        let [x1, y1, z1] = self.position();
        let [x2, y2, z2] = other.position();

        let dx = x1 - x2;
        let dy = y1 - y2;
        let dz = z1 - z2;

        -(c * dt).powi(2) + dx.powi(2) + dy.powi(2) + dz.powi(2)
    }
}
