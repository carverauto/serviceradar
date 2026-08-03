/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `VonNeumann` — face-adjacency on a regular grid (top-cube cells of `LatticeComplex<D>`).
//!
//! On a regular D-dimensional grid, two top-cubes are face-adjacent iff their positions
//! differ by exactly ±1 in exactly one coordinate axis. This yields up to `2D` neighbors
//! per cell (less near open boundaries; full on a torus).

use crate::traits::neighborhood::{CellId, Neighborhood};
use crate::types::lattice_complex::LatticeComplex;
use std::vec;

/// Von Neumann neighborhood on `LatticeComplex<D>` top cells.
///
/// Coincides with `FaceAdjacent` on top-dimensional cubes; uses grid coordinates for
/// O(D) lookup per candidate rather than walking the boundary matrix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VonNeumann;

/// Concrete iterator returned by `<VonNeumann as Neighborhood<LatticeComplex<D>>>::neighbors`.
pub struct VonNeumannIter {
    inner: vec::IntoIter<CellId>,
}

impl Iterator for VonNeumannIter {
    type Item = CellId;
    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next()
    }
}

impl<const D: usize, R: deep_causality_algebra::RealField> Neighborhood<LatticeComplex<D, R>>
    for VonNeumann
{
    type Iter<'a>
        = VonNeumannIter
    where
        LatticeComplex<D, R>: 'a;

    fn neighbors<'a>(&self, complex: &'a LatticeComplex<D, R>, cell: CellId) -> Self::Iter<'a> {
        let Some(pos) = super::cell_id_to_top_pos(complex, cell) else {
            return VonNeumannIter {
                inner: Vec::new().into_iter(),
            };
        };

        let mut neighbors: Vec<CellId> = Vec::with_capacity(2 * D);
        for axis in 0..D {
            for delta in [-1i64, 1i64] {
                let mut candidate = pos;
                if let Some(new_coord) = super::shift_coord(complex, axis, pos[axis], delta) {
                    candidate[axis] = new_coord;
                    if let Some(nid) = super::top_pos_to_cell_id(complex, candidate) {
                        neighbors.push(nid);
                    }
                }
            }
        }

        VonNeumannIter {
            inner: neighbors.into_iter(),
        }
    }
}
