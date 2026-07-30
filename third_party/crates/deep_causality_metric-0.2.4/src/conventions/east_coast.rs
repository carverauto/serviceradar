/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::conventions::LorentzianMetric;
use crate::errors::MetricError;
use crate::types::Metric;

/// A Lorentzian metric in East Coast (-+++) convention.
///
/// Also known as: MTW, Misner-Thorne-Wheeler, "mostly plus"
///
/// Properties:
/// - e₀² = -1 (time is negative)
/// - e_i² = +1 for i > 0 (space is positive)
/// - Timelike vectors: g(V,V) < 0
/// - 4-velocity: u·u = -c²
///
/// # Example
///
/// ```
/// use deep_causality_metric::{EastCoastMetric, LorentzianMetric};
///
/// let metric = EastCoastMetric::minkowski_4d();
/// assert_eq!(metric.time_sign(), -1);
/// assert_eq!(metric.space_sign(), 1);
/// assert!(metric.is_east_coast());
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct EastCoastMetric(Metric);

impl EastCoastMetric {
    /// 4D Minkowski spacetime in East Coast convention (-+++)
    pub const MINKOWSKI_4D: Self = Self(Metric::Custom {
        dim: 4,
        neg_mask: 0b0001, // bit 0 = -1 (time)
        zero_mask: 0,
    });

    /// 3D Minkowski spacetime in East Coast convention (-++)
    pub const MINKOWSKI_3D: Self = Self(Metric::Custom {
        dim: 3,
        neg_mask: 0b0001, // bit 0 = -1 (time)
        zero_mask: 0,
    });

    /// Create a new EastCoastMetric from an existing Metric.
    ///
    /// # Arguments
    /// * `metric` - The metric to wrap (must already be in East Coast convention)
    ///
    /// # Returns
    /// * `Ok(EastCoastMetric)` if the metric is in East Coast convention
    /// * `Err(MetricError)` if the metric is not in East Coast convention
    pub fn new(metric: Metric) -> Result<Self, MetricError> {
        // Validate: time (index 0) should be -1, space (index 1+) should be +1
        let dim = metric.dimension();
        if dim < 2 {
            return Err(MetricError::invalid_dimension(
                "Lorentzian metric requires at least 2 dimensions",
            ));
        }

        if metric.sign_of_sq(0) != -1 {
            return Err(MetricError::sign_convention_mismatch(
                "East Coast convention requires time (index 0) to have sign -1",
            ));
        }

        for i in 1..dim {
            let sign = metric.sign_of_sq(i);
            if sign != 1 && sign != 0 {
                return Err(MetricError::sign_convention_mismatch(
                    "East Coast convention requires space dimensions to have sign +1",
                ));
            }
        }

        Ok(Self(metric))
    }

    /// Create an EastCoastMetric by converting from a WestCoastMetric.
    ///
    /// This flips the signs to convert from (+---) to (-+++).
    pub fn from_west_coast(metric: Metric) -> Result<Self, MetricError> {
        let flipped = metric.flip_time_space();
        Self::new(flipped)
    }

    /// Create an n-dimensional East Coast Minkowski metric (-+++...+).
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

        let metric = Metric::Custom {
            dim,
            neg_mask: 0b0001, // Only time (index 0) is negative
            zero_mask: 0,
        };

        Ok(Self(metric))
    }

    /// Access the inner Metric reference.
    pub fn inner(&self) -> &Metric {
        &self.0
    }
}

impl LorentzianMetric for EastCoastMetric {
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
        -1 // East Coast: time is negative
    }

    fn space_sign(&self) -> i32 {
        1 // East Coast: space is positive
    }

    fn is_east_coast(&self) -> bool {
        true
    }

    fn is_west_coast(&self) -> bool {
        false
    }
}
