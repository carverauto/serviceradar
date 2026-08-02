/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Analytic immersed-surface primitives a cut-cell registry can be built from.

use super::source_geometry::SourceGeometry;
use deep_causality_algebra::RealField;
/// An analytic immersed surface bounding a **solid** region; the fluid is the complement.
///
/// Group A ships the closed-form analytic primitives (STL / triangle meshes are postponed —
/// design D3). Convention: the *solid body* is the region named below; the fluid is
/// everything else, and a cut-face fragment's outward normal points from the solid into the
/// fluid.
#[derive(Debug, Clone, PartialEq)]
pub enum Primitive<const D: usize, R: RealField> {
    /// Half-space solid `{ x : normal · x ≤ offset }` with a **unit** `normal`. The fluid is
    /// `{ normal · x ≥ offset }`.
    Halfspace { normal: [R; D], offset: R },
    /// Solid circular cylinder, infinite along `axis`, of the given `radius`, whose centre
    /// line passes through `center` (the `axis` component of `center` is ignored). Supported
    /// for `D = 3` (the two non-`axis` coordinates form the disk cross-section).
    Cylinder {
        axis: usize,
        center: [R; D],
        radius: R,
    },
    /// Solid ball `{ x : |x − center| ≤ radius }`. Supported for `D = 2` (a disk); the 3D ball
    /// closed form is deferred (off the cylinder-validation path).
    Ball { center: [R; D], radius: R },
}

impl<const D: usize, R: RealField> Primitive<D, R> {
    /// A half-space solid `{ normal · x ≤ offset }`, normalising `normal` to a unit vector.
    /// Returns the input unchanged (no normalisation) if `normal` is the zero vector.
    pub fn halfspace(normal: [R; D], offset: R) -> Self {
        let mut norm2 = R::zero();
        for &c in &normal {
            norm2 += c * c;
        }
        if norm2 <= R::zero() {
            return Self::Halfspace { normal, offset };
        }
        let inv = R::one() / norm2.sqrt();
        let mut unit = normal;
        for c in &mut unit {
            *c *= inv;
        }
        Self::Halfspace {
            normal: unit,
            offset: offset * inv,
        }
    }

    /// A solid circular cylinder along `axis` of the given `radius` through `center`.
    pub fn cylinder(axis: usize, center: [R; D], radius: R) -> Self {
        Self::Cylinder {
            axis,
            center,
            radius,
        }
    }

    /// A solid ball of the given `radius` centred at `center`.
    pub fn ball(center: [R; D], radius: R) -> Self {
        Self::Ball { center, radius }
    }

    /// The [`SourceGeometry`] tag for fragments clipped from this primitive.
    pub fn source(&self) -> SourceGeometry {
        match self {
            Primitive::Halfspace { .. } => SourceGeometry::Plane,
            Primitive::Cylinder { .. } => SourceGeometry::Cylinder,
            Primitive::Ball { .. } => SourceGeometry::Sphere,
        }
    }
}
