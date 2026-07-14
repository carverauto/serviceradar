/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod adjustable;
mod coordinate;
mod display;
mod getters;
mod identifiable;
mod metric_tensor;
mod space_temporal;
mod space_temporal_interval;
mod spatial;
mod temporal;

/// A 4D+4D spacetime model combining position and motion, with support for curved geometry.
///
/// `TangentBundleSpacetime` represents an event in spacetime along with its
/// tangent vector (velocity or proper motion). It also carries an embedded
/// **metric tensor** `gᵤᵥ` that defines the **local geometry** of spacetime,
/// allowing for proper interval calculations in **curved manifolds**.
///
/// This model generalizes both **flat Minkowski spacetime** and **dynamic curved spacetime**
/// (e.g., Schwarzschild or cosmological spacetimes) by exposing its metric via the
/// `MetricTensor4D` trait, and supporting runtime updates via
/// `update_metric_tensor()`.
///
/// # Fields
/// - `id`: Unique numeric identifier
/// - `x`: X-coordinate in meters
/// - `y`: Y-coordinate in meters
/// - `z`: Z-coordinate in meters
/// - `t`: time (e.g., seconds)
/// - `dt`: Proper time velocity (usually `1.0`)
/// - `dx, dy, dz`: Spatial velocity components (in meters/second)
/// - `metric`: Local 4×4 metric tensor defining the geometry
///
/// # Coordinate Index Mapping
/// When used with the `Coordinate` trait, the following index mapping applies:
/// - `0 => x`
/// - `1 => y`
/// - `2 => z`
/// - `3 => t`
///
/// # Curvature Support
/// The default metric is flat Minkowski (− + + +), but this can be replaced at runtime:
///
/// ```
/// use deep_causality::*;
///
/// let mut s = TangentSpacetime::new(1, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0);
///
/// // Replace with a custom curved spacetime metric (e.g., anisotropic)
/// let warped = [
///     [-8.98755179e16, 0.0, 0.0, 0.0],
///     [0.0, 1.05, 0.0, 0.0],
///     [0.0, 0.0, 0.95, 0.0],
///     [0.0, 0.0, 0.0, 0.90],
/// ];
///
/// s.update_metric_tensor(warped);
/// let s2 = TangentSpacetime::new(2, 2.0, 3.0, 4.0, 0.0, 1.0, 0.0, 0.0, 0.0);
///
/// let interval = s.interval_squared(&s2);
/// println!("Curved spacetime interval²: {interval}");
/// ```
///
/// # References
/// - J.M. Lee, *Introduction to Smooth Manifolds*, Springer, 2012 — Chapter 8: Tangent Bundles
/// - R.M. Wald, *General Relativity*, University of Chicago Press, 1984 — Ch. 3: Curved Spacetime Geometry
///
/// # See also
/// - `SpacetimeInterval` — for causal separation calculations
/// - `MetricTensor4D` — for curvature configuration
#[derive(Debug, Copy, Clone, PartialEq)]
pub struct TangentSpacetime {
    id: u64,

    // Position
    x: f64, // meters
    y: f64,
    z: f64,

    // Time
    t: f64, // seconds

    // Velocity / tangent vector
    dt: f64, // unit or proper time derivative
    dx: f64, // meters/second
    dy: f64,
    dz: f64,

    // Local metric tensor (mutable)
    metric: [[f64; 4]; 4],
}

impl TangentSpacetime {
    /// Create a new tangent bundle point with a default Minkowski metric.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: u64,
        x: f64,
        y: f64,
        z: f64,
        t: f64,
        dt: f64,
        dx: f64,
        dy: f64,
        dz: f64,
    ) -> Self {
        let c = 299_792_458.0;
        let metric = [
            [-c * c, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ];

        Self {
            id,
            t,
            x,
            y,
            z,
            dt,
            dx,
            dy,
            dz,
            metric,
        }
    }
}
