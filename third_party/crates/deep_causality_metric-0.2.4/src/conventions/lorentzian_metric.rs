/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::fmt::Debug;

use crate::types::Metric;

/// Trait for convention-specific Lorentzian metric wrappers.
///
/// Implemented by `EastCoastMetric` and `WestCoastMetric`.
///
/// # Sign Conventions
///
/// | Convention | Signature | g_{μν} | Time Sign | Space Sign |
/// |------------|-----------|--------|-----------|------------|
/// | East Coast | (-+++) | diag(-1,1,1,1) | -1 | +1 |
/// | West Coast | (+---) | diag(1,-1,-1,-1) | +1 | -1 |
pub trait LorentzianMetric: Clone + Copy + Debug + PartialEq {
    /// Access the underlying `Metric`
    fn as_metric(&self) -> &Metric;

    /// Consume and return the underlying `Metric`
    fn into_metric(self) -> Metric;

    /// Standard 4D Minkowski spacetime for this convention
    fn minkowski_4d() -> Self;

    /// Standard 3D Minkowski spacetime for this convention
    fn minkowski_3d() -> Self;

    /// Returns the sign of the time component: -1 for East Coast, +1 for West Coast
    fn time_sign(&self) -> i32;

    /// Returns the sign of a spatial component (index 1)
    fn space_sign(&self) -> i32;

    /// Returns true if this is the East Coast (-+++) convention
    fn is_east_coast(&self) -> bool;

    /// Returns true if this is the West Coast (+---) convention
    fn is_west_coast(&self) -> bool;

    /// Returns the spacetime dimension
    fn dimension(&self) -> usize {
        self.as_metric().dimension()
    }

    /// Returns the (p, q, r) signature tuple
    fn signature(&self) -> (usize, usize, usize) {
        self.as_metric().signature()
    }
}
