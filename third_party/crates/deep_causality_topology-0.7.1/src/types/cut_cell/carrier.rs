/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The per-cell cut-geometry overlay record.

use super::cell_class::CellClass;
use super::cut_face_fragment::CutFaceFragment;
use deep_causality_algebra::RealField;
/// The cut-geometry overlay for a single intersected lattice cell.
///
/// A `CutCell` is the fractional-aperture generalisation of the Stage-3 axis-aligned wall
/// clip: it records the clipped fluid volume, the per-face wetted fractions (apertures),
/// the cut-face fragments, and the [`CellClass`]. All volumes and areas are **measures**
/// (integrals over the cell, in physical units), so they feed the existing cell-volume /
/// Hodge-star dispatch directly — never as pointwise field values.
///
/// Apertures are stored per axis as `[low, high]`: `apertures[a][0]` is the wetted fraction
/// of the `(D−1)`-face perpendicular to axis `a` at the cell's lower bound (`position[a]`),
/// and `apertures[a][1]` the face at the upper bound (`position[a] + 1`). Each is in
/// `[0, 1]`.
#[derive(Debug, Clone, PartialEq)]
pub struct CutCell<const D: usize, R: RealField> {
    class: CellClass,
    fluid_volume: R,
    full_volume: R,
    apertures: [[R; 2]; D],
    fragments: Vec<CutFaceFragment<D, R>>,
}

impl<const D: usize, R: RealField> CutCell<D, R> {
    /// A fully-wetted cell: clipped volume equals the full cell volume, every aperture is
    /// `1`, no fragments. (Recorded explicitly only when a caller wants a dense registry;
    /// normally fluid cells are simply absent from the registry.)
    pub fn fluid(full_volume: R) -> Self {
        Self {
            class: CellClass::Fluid,
            fluid_volume: full_volume,
            full_volume,
            apertures: [[R::one(); 2]; D],
            fragments: Vec::new(),
        }
    }

    /// A fully-dry cell: clipped volume `0`, every aperture `0`, no fragments.
    pub fn solid(full_volume: R) -> Self {
        Self {
            class: CellClass::Solid,
            fluid_volume: R::zero(),
            full_volume,
            apertures: [[R::zero(); 2]; D],
            fragments: Vec::new(),
        }
    }

    /// A partially-wetted (cut) cell from its clipped fluid volume, per-face apertures, and
    /// cut-face fragments. `full_volume` is the uncut cell measure (used for the volume
    /// fraction); `fluid_volume` is the wetted part.
    pub fn cut(
        full_volume: R,
        fluid_volume: R,
        apertures: [[R; 2]; D],
        fragments: Vec<CutFaceFragment<D, R>>,
    ) -> Self {
        Self {
            class: CellClass::Cut,
            fluid_volume,
            full_volume,
            apertures,
            fragments,
        }
    }

    /// The cell's classification.
    pub fn class(&self) -> CellClass {
        self.class
    }

    /// The clipped fluid volume (physical measure). Equals the full volume for a fluid
    /// cell and `0` for a solid cell.
    pub fn fluid_volume(&self) -> R {
        self.fluid_volume
    }

    /// The full (uncut) cell volume.
    pub fn full_volume(&self) -> R {
        self.full_volume
    }

    /// The wetted volume fraction `fluid_volume / full_volume` in `[0, 1]`. Returns `0` for
    /// a degenerate zero-volume cell rather than dividing by zero.
    pub fn volume_fraction(&self) -> R {
        if self.full_volume == R::zero() {
            R::zero()
        } else {
            self.fluid_volume / self.full_volume
        }
    }

    /// All per-axis `[low, high]` face apertures.
    pub fn apertures(&self) -> &[[R; 2]; D] {
        &self.apertures
    }

    /// The wetted fraction of the face perpendicular to `axis` on the given `side`
    /// (`0` = low / `position[axis]`, `1` = high / `position[axis] + 1`). Returns `None`
    /// for an out-of-range `axis` or `side`.
    pub fn face_aperture(&self, axis: usize, side: usize) -> Option<R> {
        if axis >= D || side >= 2 {
            return None;
        }
        Some(self.apertures[axis][side])
    }

    /// The cut-face fragments inside this cell.
    pub fn fragments(&self) -> &[CutFaceFragment<D, R>] {
        &self.fragments
    }
}
