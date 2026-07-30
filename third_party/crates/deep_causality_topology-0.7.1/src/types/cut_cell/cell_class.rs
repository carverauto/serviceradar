/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Fluid / cut / solid classification of a lattice cell against an immersed surface.

/// Where a lattice cell sits relative to an immersed surface.
///
/// A cut-cell registry stores only the [`CellClass::Cut`] (and, for bookkeeping, any
/// explicitly recorded [`CellClass::Solid`]) cells; every cell absent from the registry is
/// implicitly [`CellClass::Fluid`] and takes the existing uniform fast path. See
/// `openspec/changes/add-cut-cells-and-immersed-boundaries` (CFD Stage 4, Group A).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CellClass {
    /// Fully wetted: the cell lies entirely in the fluid region. Clipped volume equals the
    /// full cell volume and every face aperture is `1`.
    Fluid,
    /// Partially wetted: the immersed surface passes through the cell. The cell carries a
    /// clipped fluid volume in `(0, full)`, per-face apertures in `[0, 1]`, and one or more
    /// cut-face fragments.
    Cut,
    /// Fully dry: the cell lies entirely inside the solid body. Clipped volume is `0` and
    /// every face aperture is `0`.
    Solid,
}

impl CellClass {
    /// `true` for [`CellClass::Fluid`].
    pub fn is_fluid(self) -> bool {
        matches!(self, CellClass::Fluid)
    }

    /// `true` for [`CellClass::Cut`].
    pub fn is_cut(self) -> bool {
        matches!(self, CellClass::Cut)
    }

    /// `true` for [`CellClass::Solid`].
    pub fn is_solid(self) -> bool {
        matches!(self, CellClass::Solid)
    }
}
