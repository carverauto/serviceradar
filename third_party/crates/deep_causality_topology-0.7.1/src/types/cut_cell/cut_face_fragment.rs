/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! A single piece of immersed surface inside one lattice cell.

use super::source_geometry::SourceGeometry;
use deep_causality_algebra::RealField;
/// A cut-face fragment: the portion of an immersed surface that lies inside one lattice
/// cell, summarised as a flat facet.
///
/// Carries the fragment's `(D−1)`-area (a *measure*, in physical units — the same
/// cochain convention the `graded-metrics` capability established), its outward unit
/// normal pointing **from the solid body into the fluid**, a representative **centroid**
/// (a point on the wetted surface, in the same physical coordinates as the lattice nodes),
/// and a [`SourceGeometry`] tag.
/// For a planar cut the area is the exact closed-form cross-section; for a curved surface
/// (cylinder) the area is the high-resolution-quadrature surface measure and the stored
/// normal is the area-representative outward direction over the fragment. The centroid
/// anchors the wall location for the one-sided wall-normal friction diagnostic (the true
/// distance `Δh`, Kirkpatrick 2003). The fragment feeds the Stage-4 immersed-wall BC stage;
/// it is not on the cut-geometry exactness scenario, which gates clipped volume and apertures.
#[derive(Debug, Clone, PartialEq)]
pub struct CutFaceFragment<const D: usize, R: RealField> {
    area: R,
    outward_normal: [R; D],
    centroid: [R; D],
    source: SourceGeometry,
}

impl<const D: usize, R: RealField> CutFaceFragment<D, R> {
    /// Build a fragment from its area, outward unit normal, surface centroid, and source tag.
    ///
    /// The normal is taken as already normalised; callers in the intersection routines
    /// construct it from the analytic surface gradient. The centroid is a representative point
    /// lying on the wetted surface (physical lattice coordinates), used to anchor the wall in
    /// the friction diagnostic.
    pub fn new(area: R, outward_normal: [R; D], centroid: [R; D], source: SourceGeometry) -> Self {
        Self {
            area,
            outward_normal,
            centroid,
            source,
        }
    }

    /// The fragment's `(D−1)`-area (physical measure).
    pub fn area(&self) -> R {
        self.area
    }

    /// Outward unit normal, pointing from the solid body into the fluid.
    pub fn outward_normal(&self) -> &[R; D] {
        &self.outward_normal
    }

    /// A representative point on the wetted surface (physical lattice coordinates) — the wall
    /// anchor for the one-sided wall-normal friction diagnostic.
    pub fn centroid(&self) -> &[R; D] {
        &self.centroid
    }

    /// The immersed-surface family this fragment was clipped from.
    pub fn source(&self) -> SourceGeometry {
        self.source
    }
}
