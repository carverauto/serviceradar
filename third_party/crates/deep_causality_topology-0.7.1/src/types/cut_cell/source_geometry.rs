/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tag identifying which immersed surface produced a cut-face fragment.

/// The kind of immersed surface a [`crate::CutFaceFragment`] was clipped from.
///
/// Group A ships the analytic primitives only (`STL` ingestion is postponed — see the
/// change's design D3). The tag lets a downstream BC stage (Stage 4 Group B) recover the
/// surface family a fragment belongs to without re-deriving it from the normal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SourceGeometry {
    /// A planar half-space cut.
    Plane,
    /// An (axis-aligned) circular cylinder.
    Cylinder,
    /// A sphere / 2D disk.
    Sphere,
}
