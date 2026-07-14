/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::IndexError;
use crate::{
    Coordinate, EuclideanSpacetime, Identifiable, LorentzianSpacetime, MinkowskiSpacetime,
    SpaceTemporal, Spatial, TangentSpacetime, Temporal, TimeScale,
};
use std::fmt::Formatter;

/// A polymorphic enum over supported spacetime context types.
///
/// `SpaceTimeKind` provides a unified abstraction over multiple spacetime representations.
/// It enables algorithms to generically operate over different mathematical models of
/// space and time without requiring monomorphic type coupling.
///
/// This type implements key traits such as [`Coordinate`], [`Temporal`], [`Spatial`], and
/// [`SpaceTemporal`] to enable high-level reasoning, measurement, and causal modeling in spacetime-aware systems.
///
/// # Supported Variants
///
/// - [`EuclideanSpacetime`]: Classical Newtonian model with separate space and time.
/// - [`LorentzianSpacetime`]: Supports pseudo-Riemannian geometry, used in general relativity.
/// - [`MinkowskiSpacetime`]: Flat spacetime in special relativity, often used in causal graphs.
/// - [`TangentSpacetime`]: Linear approximation of curved space at a point (i.e., tangent space).
///
/// # Examples
///
/// ```rust
/// use deep_causality::*;
///
/// let euclidean = EuclideanSpacetime::new(1, 0.0, 0.0, 0.0, 1.0, TimeScale::Second);
/// let spacetime = SpaceTimeKind::Euclidean(euclidean);
///
/// assert_eq!(spacetime.dimension(), 4);
/// assert_eq!(spacetime.time_unit(), 1.0);
/// ```
///
/// # Trait Support
///
/// `SpaceTimeKind` implements:
///
/// - [`Identifiable`]: Unique ID for referencing entities.
/// - [`Coordinate<f64>`]: Spatial dimensionality and index access.
/// - [`Temporal<f64>`]: Temporal metadata and tick-based behavior.
/// - [`Spatial<f64>`]: Marker trait for spatial context.
/// - [`SpaceTemporal<f64, f64>`]: Full space-time reasoning abstraction.
///
/// # Index Mapping
/// Coordinate indexing depends on the inner type variant. The most common mapping is:
/// - `0 => x`
/// - `1 => y`
/// - `2 => z`
/// - `3 => t`
///
/// # Notes
/// - This abstraction is ideal for heterogeneous systems that must support multiple
///   physical or geometric models simultaneously (e.g., causal simulation engines,
///   robotics frameworks, or time-aware decision systems).
#[derive(Debug, Clone, PartialEq)]
pub enum SpaceTimeKind {
    /// Classical Newtonian spacetime (ℝ³ + time)
    Euclidean(EuclideanSpacetime),
    /// General relativistic curved spacetime
    Lorentzian(LorentzianSpacetime),
    /// Special relativistic flat spacetime (Minkowski space)
    Minkowski(MinkowskiSpacetime),
    /// Tangent space at a point, used for local linearization of curvature
    Tangent(TangentSpacetime),
}

impl Coordinate<f64> for SpaceTimeKind {
    fn dimension(&self) -> usize {
        match self {
            SpaceTimeKind::Euclidean(euclidean) => euclidean.dimension(),
            SpaceTimeKind::Lorentzian(lorentzian) => lorentzian.dimension(),
            SpaceTimeKind::Minkowski(minkowski) => minkowski.dimension(),
            SpaceTimeKind::Tangent(tangent) => tangent.dimension(),
        }
    }

    fn coordinate(&self, index: usize) -> Result<&f64, IndexError> {
        match self {
            SpaceTimeKind::Euclidean(euclidean) => euclidean.coordinate(index),
            SpaceTimeKind::Lorentzian(lorentzian) => lorentzian.coordinate(index),
            SpaceTimeKind::Minkowski(minkowski) => minkowski.coordinate(index),
            SpaceTimeKind::Tangent(tangent) => tangent.coordinate(index),
        }
    }
}

impl Identifiable for SpaceTimeKind {
    fn id(&self) -> u64 {
        match self {
            SpaceTimeKind::Euclidean(euclidean) => euclidean.id(),
            SpaceTimeKind::Lorentzian(lorentzian) => lorentzian.id(),
            SpaceTimeKind::Minkowski(minkowski) => minkowski.id(),
            SpaceTimeKind::Tangent(tangent) => tangent.id(),
        }
    }
}

impl Spatial<f64> for SpaceTimeKind {}

impl Temporal<f64> for SpaceTimeKind {
    fn time_scale(&self) -> TimeScale {
        match self {
            SpaceTimeKind::Euclidean(euclidean) => euclidean.time_scale(),
            SpaceTimeKind::Lorentzian(lorentzian) => lorentzian.time_scale(),
            SpaceTimeKind::Minkowski(minkowski) => minkowski.time_scale(),
            SpaceTimeKind::Tangent(tangent) => tangent.time_scale(),
        }
    }

    fn time_unit(&self) -> f64 {
        match self {
            SpaceTimeKind::Euclidean(euclidean) => euclidean.time_unit(),
            SpaceTimeKind::Lorentzian(lorentzian) => lorentzian.time_unit(),
            SpaceTimeKind::Minkowski(minkowski) => minkowski.time_unit(),
            SpaceTimeKind::Tangent(tangent) => tangent.time_unit(),
        }
    }
}

impl SpaceTemporal<f64, f64> for SpaceTimeKind {
    fn t(&self) -> &f64 {
        match self {
            SpaceTimeKind::Euclidean(euclidean) => euclidean.t(),
            SpaceTimeKind::Lorentzian(lorentzian) => lorentzian.t(),
            SpaceTimeKind::Minkowski(minkowski) => minkowski.t(),
            SpaceTimeKind::Tangent(tangent) => tangent.t(),
        }
    }
}

impl std::fmt::Display for SpaceTimeKind {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            SpaceTimeKind::Euclidean(euclidean) => euclidean.fmt(f),
            SpaceTimeKind::Lorentzian(lorentzian) => lorentzian.fmt(f),
            SpaceTimeKind::Minkowski(minkowski) => minkowski.fmt(f),
            SpaceTimeKind::Tangent(tangent) => tangent.fmt(f),
        }
    }
}
