/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Concrete neighborhood strategies for the `Neighborhood<K: ChainComplex>` trait.
//!
//! Two layers:
//!   * **Chain-complex-generic**: `FaceAdjacent`, `CofaceAdjacent` — defined via ∂ / δ
//!     on any `ChainComplex`. Work for simplicial, cubical, and user-defined complexes.
//!   * **Grid-only**: `VonNeumann`, `Moore`, `KRing<const K>` — implemented for
//!     `LatticeComplex<D>` only. They rely on the regular-grid coordinate structure and
//!     Chebyshev metric, which have no principled simplicial analogue.
//!
//! Users add their own strategies (anisotropic LIDAR cones, half-space RF, etc.) by
//! implementing `Neighborhood<K>` for their own zero-sized types — no fork needed.

mod coface_adjacent;
mod face_adjacent;
mod k_ring;
mod moore;
mod von_neumann;

pub use coface_adjacent::{CofaceAdjacent, CofaceAdjacentIter};
pub use face_adjacent::{FaceAdjacent, FaceAdjacentIter};
pub use k_ring::{KRing, KRingIter};
pub use moore::{Moore, MooreIter};
pub use von_neumann::{VonNeumann, VonNeumannIter};

// ---------------------------------------------------------------------------
// Shared grid coordinate helpers for `LatticeComplex<D>` strategies.
//
// Top-cell linear index ↔ grid position. Convention matches `LatticeCellIterator`
// for grade D: position[0] varies fastest, then position[1], etc. Valid position
// range per dimension is `0..shape[i]` for periodic axes and `0..shape[i]-1` for
// open axes (since open top cubes need at least one cell to their right).
// ---------------------------------------------------------------------------

use crate::traits::neighborhood::CellId;
use crate::types::lattice_complex::LatticeComplex;

/// Maximum coordinate (exclusive upper bound) for top-cube positions along axis `axis`.
fn top_axis_range<const D: usize, R: deep_causality_algebra::RealField>(
    complex: &LatticeComplex<D, R>,
    axis: usize,
) -> usize {
    let shape = complex.shape()[axis];
    if complex.periodic()[axis] {
        shape
    } else if shape == 0 {
        0
    } else {
        shape - 1
    }
}

/// Linear cell_id → grid position for top cubes. `None` if `cell_id` is out of range.
#[allow(clippy::needless_range_loop)]
pub(super) fn cell_id_to_top_pos<const D: usize, R: deep_causality_algebra::RealField>(
    complex: &LatticeComplex<D, R>,
    cell_id: CellId,
) -> Option<[usize; D]> {
    let mut pos = [0usize; D];
    let mut remaining = cell_id;
    for i in 0..D {
        let dim_max = top_axis_range(complex, i);
        if dim_max == 0 {
            return None;
        }
        pos[i] = remaining % dim_max;
        remaining /= dim_max;
    }
    if remaining == 0 { Some(pos) } else { None }
}

/// Grid position → linear cell_id. `None` if any coordinate is out of range.
#[allow(clippy::needless_range_loop)]
pub(super) fn top_pos_to_cell_id<const D: usize, R: deep_causality_algebra::RealField>(
    complex: &LatticeComplex<D, R>,
    pos: [usize; D],
) -> Option<CellId> {
    let mut cell_id = 0usize;
    let mut stride = 1usize;
    for i in 0..D {
        let dim_max = top_axis_range(complex, i);
        if dim_max == 0 || pos[i] >= dim_max {
            return None;
        }
        cell_id += pos[i] * stride;
        stride *= dim_max;
    }
    Some(cell_id)
}

/// Shift one coordinate by `delta`. Honors periodic vs open boundaries.
/// Returns `None` if the shifted coordinate lies outside an open boundary.
pub(super) fn shift_coord<const D: usize, R: deep_causality_algebra::RealField>(
    complex: &LatticeComplex<D, R>,
    axis: usize,
    coord: usize,
    delta: i64,
) -> Option<usize> {
    let dim_max = top_axis_range(complex, axis);
    if dim_max == 0 {
        return None;
    }
    let raw = coord as i64 + delta;
    if complex.periodic()[axis] {
        let m = dim_max as i64;
        let wrapped = ((raw % m) + m) % m;
        Some(wrapped as usize)
    } else if raw < 0 || raw >= dim_max as i64 {
        None
    } else {
        Some(raw as usize)
    }
}
