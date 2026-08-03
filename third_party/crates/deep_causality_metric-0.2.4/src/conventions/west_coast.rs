/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::conventions::LorentzianMetric;
use crate::errors::MetricError;
use crate::types::Metric;

/// A Lorentzian metric in West Coast (+---) convention.
///
/// Also known as: Weinberg, Particle Physics, "mostly minus"
///
/// Properties:
/// - e₀² = +1 (time is positive)
/// - e_i² = -1 for i > 0 (space is negative)
/// - Timelike vectors: g(V,V) > 0
/// - 4-velocity: u·u = +c²
///
/// # Example
///
/// ```
/// use deep_causality_metric::{WestCoastMetric, LorentzianMetric};
///
/// let metric = WestCoastMetric::minkowski_4d();
/// assert_eq!(metric.time_sign(), 1);
/// assert_eq!(metric.space_sign(), -1);
/// assert!(metric.is_west_coast());
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WestCoastMetric(Metric);

impl WestCoastMetric {
    /// 4D Minkowski spacetime in West Coast convention (+---)
    pub const MINKOWSKI_4D: Self = Self(Metric::Minkowski(4));

    /// 3D Minkowski spacetime in West Coast convention (+--)
    pub const MINKOWSKI_3D: Self = Self(Metric::Minkowski(3));

    /// Create a new WestCoastMetric from an existing Metric.
    ///
    /// # Arguments
    /// * `metric` - The metric to wrap (must already be in West Coast convention)
    ///
    /// # Returns
    /// * `Ok(WestCoastMetric)` if the metric is in West Coast convention
    /// * `Err(MetricError)` if the metric is not in West Coast convention
    pub fn new(metric: Metric) -> Result<Self, MetricError> {
        // Validate: time (index 0) should be +1, space (index 1+) should be -1
        let dim = metric.dimension();
        if dim < 2 {
            return Err(MetricError::invalid_dimension(
                "Lorentzian metric requires at least 2 dimensions",
            ));
        }

        if metric.sign_of_sq(0) != 1 {
            return Err(MetricError::sign_convention_mismatch(
                "West Coast convention requires time (index 0) to have sign +1",
            ));
        }

        for i in 1..dim {
            let sign = metric.sign_of_sq(i);
            if sign != -1 && sign != 0 {
                return Err(MetricError::sign_convention_mismatch(
                    "West Coast convention requires space dimensions to have sign -1",
                ));
            }
        }

        Ok(Self(metric))
    }

    /// Create a WestCoastMetric by converting from an EastCoastMetric.
    ///
    /// This flips the signs to convert from (-+++) to (+---).
    pub fn from_east_coast(metric: Metric) -> Result<Self, MetricError> {
        let flipped = metric.flip_time_space();
        Self::new(flipped)
    }

    /// Create an n-dimensional West Coast Minkowski metric (+---...-).
    ///
    /// # Arguments
    /// * `dim` - The total dimension (must be >= 2 and <= 64)
    pub fn new_nd(dim: usize) -> Result<Self, MetricError> {
        if dim < 2 {
            return Err(MetricError::invalid_dimension(
                "Lorentzian metric requires at least 2 dimensions",
            ));
        }
        if dim > 64 {
            return Err(MetricError::invalid_dimension(
                "dimension exceeds bitmask capacity (max 64)",
            ));
        }

        // Use Minkowski variant for standard West Coast convention
        Ok(Self(Metric::Minkowski(dim)))
    }

    /// Access the inner Metric reference.
    pub fn inner(&self) -> &Metric {
        &self.0
    }
}

impl LorentzianMetric for WestCoastMetric {
    fn as_metric(&self) -> &Metric {
        &self.0
    }

    fn into_metric(self) -> Metric {
        self.0
    }

    fn minkowski_4d() -> Self {
        Self::MINKOWSKI_4D
    }

    fn minkowski_3d() -> Self {
        Self::MINKOWSKI_3D
    }

    fn time_sign(&self) -> i32 {
        1 // West Coast: time is positive
    }

    fn space_sign(&self) -> i32 {
        -1 // West Coast: space is negative
    }

    fn is_east_coast(&self) -> bool {
        false
    }

    fn is_west_coast(&self) -> bool {
        true
    }
}
