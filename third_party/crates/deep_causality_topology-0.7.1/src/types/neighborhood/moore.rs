/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `Moore` — Moore neighborhood on a regular grid (top-cube cells of `LatticeComplex<D>`).
//!
//! All cells at Chebyshev distance ≤ 1 from the target, excluding the target itself.
//! Yields up to `3^D − 1` neighbors per cell (8 in 2D, 26 in 3D), trimmed near open
//! boundaries.

use crate::traits::neighborhood::{CellId, Neighborhood};
use crate::types::lattice_complex::LatticeComplex;
use std::vec;

/// Moore neighborhood on `LatticeComplex<D>` top cells (Chebyshev distance = 1).
///
/// Grid-only by design: the regular coordinate / Chebyshev-metric structure has no
/// principled simplicial analogue (see design D5).
///
/// `Moore` is implemented only for `Neighborhood<LatticeComplex<D>>` — not for
/// `SimplicialComplex<_>` or any other chain complex. The following snippet MUST fail
/// to compile:
///
/// ```compile_fail
/// use deep_causality_topology::{Moore, Neighborhood, SimplicialComplex, SimplicialComplexBuilder, Simplex};
/// let complex: SimplicialComplex<f64> = SimplicialComplexBuilder::new(2).build().unwrap();
/// // Moore does not implement Neighborhood<SimplicialComplex<f64>>:
/// let _ = Moore.neighbors(&complex, 0);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Moore;

/// Concrete iterator returned by `<Moore as Neighborhood<LatticeComplex<D>>>::neighbors`.
pub struct MooreIter {
    inner: vec::IntoIter<CellId>,
}

impl Iterator for MooreIter {
    type Item = CellId;
    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next()
    }
}

impl<const D: usize, R: deep_causality_algebra::RealField> Neighborhood<LatticeComplex<D, R>>
    for Moore
{
    type Iter<'a>
        = MooreIter
    where
        LatticeComplex<D, R>: 'a;

    #[allow(clippy::needless_range_loop)]
    fn neighbors<'a>(&self, complex: &'a LatticeComplex<D, R>, cell: CellId) -> Self::Iter<'a> {
        let Some(pos) = super::cell_id_to_top_pos(complex, cell) else {
            return MooreIter {
                inner: Vec::new().into_iter(),
            };
        };

        // Iterate over all offsets in {-1, 0, 1}^D except all-zero.
        let total: usize = 3usize.pow(D as u32);
        let mut neighbors: Vec<CellId> = Vec::with_capacity(total - 1);
        for mask in 0..total {
            // Decode mask into offset[0..D] in {-1, 0, 1}.
            let mut offset = [0i64; D];
            let mut m = mask;
            let mut all_zero = true;
            for i in 0..D {
                let d = (m % 3) as i64 - 1;
                offset[i] = d;
                if d != 0 {
                    all_zero = false;
                }
                m /= 3;
            }
            if all_zero {
                continue;
            }

            // Apply offset axis-by-axis; bail if any axis goes out of bounds.
            let mut candidate = pos;
            let mut in_bounds = true;
            for i in 0..D {
                if offset[i] == 0 {
                    continue;
                }
                match super::shift_coord(complex, i, candidate[i], offset[i]) {
                    Some(new_coord) => candidate[i] = new_coord,
                    None => {
                        in_bounds = false;
                        break;
                    }
                }
            }
            if !in_bounds {
                continue;
            }
            if let Some(nid) = super::top_pos_to_cell_id(complex, candidate) {
                neighbors.push(nid);
            }
        }

        MooreIter {
            inner: neighbors.into_iter(),
        }
    }
}
