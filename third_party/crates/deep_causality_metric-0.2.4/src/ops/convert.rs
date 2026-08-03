/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Conversion operations for metrics.
//!
//! This module provides utilities for converting between different metric
//! representations and conventions.

use crate::conventions::{EastCoastMetric, WestCoastMetric};
use crate::errors::MetricError;
use crate::types::Metric;

/// Convert a West Coast (+---) metric to East Coast (-+++).
///
/// This is a convenience function that wraps `EastCoastMetric::from_west_coast`.
pub fn west_to_east(metric: &Metric) -> Result<EastCoastMetric, MetricError> {
    EastCoastMetric::from_west_coast(*metric)
}

/// Convert an East Coast (-+++) metric to West Coast (+---).
///
/// This is a convenience function that wraps `WestCoastMetric::from_east_coast`.
pub fn east_to_west(metric: &Metric) -> Result<WestCoastMetric, MetricError> {
    WestCoastMetric::from_east_coast(*metric)
}

/// Attempt to detect the sign convention of a Lorentzian metric.
///
/// # Returns
/// - `Some(true)` if East Coast (-+++)
/// - `Some(false)` if West Coast (+---)
/// - `None` if neither (e.g., Euclidean, PGA, or non-standard)
pub fn detect_convention(metric: &Metric) -> Option<bool> {
    let dim = metric.dimension();
    if dim < 2 {
        return None;
    }

    let time_sign = metric.sign_of_sq(0);
    let space_sign = metric.sign_of_sq(1);

    match (time_sign, space_sign) {
        (-1, 1) => Some(true),  // East Coast
        (1, -1) => Some(false), // West Coast
        _ => None,              // Neither
    }
}

/// Check if a metric is a valid Lorentzian metric (has one time dimension).
///
/// A valid Lorentzian metric has exactly one timelike direction and
/// (n-1) spacelike directions.
pub fn is_lorentzian(metric: &Metric) -> bool {
    let (p, q, _r) = metric.signature();

    // East Coast: (n-1, 1, 0) - one negative (time), rest positive
    // West Coast: (1, n-1, 0) - one positive (time), rest negative
    (p == 1 && q >= 1) || (q == 1 && p >= 1)
}
