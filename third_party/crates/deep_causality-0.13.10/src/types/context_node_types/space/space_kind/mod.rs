/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::IndexError;
use crate::{
    Coordinate, EcefSpace, EuclideanSpace, GeoSpace, Identifiable, NedSpace, QuaternionSpace,
    Spatial,
};

/// An enumeration over supported spatial context types.
///
/// This abstraction allows unified handling of multiple space types:
/// - Geodetic (`GeoSpace`)
/// - Euclidean (`EuclideanSpace`)
/// - Cartesian Earth-fixed (`EcefSpace`)
/// - Local tangent frame (`NedSpace`)
/// - 3D orientation (`QuaternionSpace`)
#[derive(Debug, Clone, PartialEq)]
pub enum SpaceKind {
    Geo(GeoSpace),
    Ecef(EcefSpace),
    Euclidean(EuclideanSpace),
    Ned(NedSpace),
    Quaternion(QuaternionSpace),
}

impl Coordinate<f64> for SpaceKind {
    fn dimension(&self) -> usize {
        match self {
            SpaceKind::Geo(s) => s.dimension(),
            SpaceKind::Ecef(s) => s.dimension(),
            SpaceKind::Euclidean(s) => s.dimension(),
            SpaceKind::Ned(s) => s.dimension(),
            SpaceKind::Quaternion(s) => s.dimension(),
        }
    }

    fn coordinate(&self, index: usize) -> Result<&f64, IndexError> {
        match self {
            SpaceKind::Geo(s) => s.coordinate(index),
            SpaceKind::Ecef(s) => s.coordinate(index),
            SpaceKind::Euclidean(s) => s.coordinate(index),
            SpaceKind::Ned(s) => s.coordinate(index),
            SpaceKind::Quaternion(s) => s.coordinate(index),
        }
    }
}

impl Identifiable for SpaceKind {
    fn id(&self) -> u64 {
        match self {
            SpaceKind::Geo(s) => s.id(),
            SpaceKind::Ecef(s) => s.id(),
            SpaceKind::Euclidean(s) => s.id(),
            SpaceKind::Ned(s) => s.id(),
            SpaceKind::Quaternion(s) => s.id(),
        }
    }
}

impl Spatial<f64> for SpaceKind {}

impl std::fmt::Display for SpaceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SpaceKind::Geo(s) => write!(f, "{s}"),
            SpaceKind::Ecef(s) => write!(f, "{s}"),
            SpaceKind::Euclidean(s) => write!(f, "{s}"),
            SpaceKind::Ned(s) => write!(f, "{s}"),
            SpaceKind::Quaternion(s) => write!(f, "{s}"),
        }
    }
}
