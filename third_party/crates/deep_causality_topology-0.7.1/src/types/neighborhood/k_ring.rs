/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `KRing<const K>` — Chebyshev-distance-≤-K neighborhood on `LatticeComplex<D>`.
//!
//! Generalizes `Moore` (which is `KRing<1>`): yields up to `(2K + 1)^D − 1` cells per
//! target, trimmed near open boundaries.

use crate::traits::neighborhood::{CellId, Neighborhood};
use crate::types::lattice_complex::LatticeComplex;
use std::vec;

/// Chebyshev-distance-≤-K neighborhood on `LatticeComplex<D>` top cells.
///
/// `KRing<1>` is equivalent to `Moore`. Grid-only by design.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct KRing<const K: usize>;

/// Concrete iterator returned by `<KRing<K> as Neighborhood<LatticeComplex<D>>>::neighbors`.
pub struct KRingIter {
    inner: vec::IntoIter<CellId>,
}

impl Iterator for KRingIter {
    type Item = CellId;
    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next()
    }
}

impl<const K: usize, const D: usize, R: deep_causality_algebra::RealField>
    Neighborhood<LatticeComplex<D, R>> for KRing<K>
{
    type Iter<'a>
        = KRingIter
    where
        LatticeComplex<D, R>: 'a;

    #[allow(clippy::needless_range_loop)]
    fn neighbors<'a>(&self, complex: &'a LatticeComplex<D, R>, cell: CellId) -> Self::Iter<'a> {
        let Some(pos) = super::cell_id_to_top_pos(complex, cell) else {
            return KRingIter {
                inner: Vec::new().into_iter(),
            };
        };
        if K == 0 {
            return KRingIter {
                inner: Vec::new().into_iter(),
            };
        }

        let side = 2 * K + 1; // number of offsets per axis: -K..=K
        let total: usize = side.pow(D as u32);
        let k_i64 = K as i64;
        let mut neighbors: Vec<CellId> = Vec::new();

        for mask in 0..total {
            // Decode mask into offset[0..D] in {-K..=K}.
            let mut offset = [0i64; D];
            let mut m = mask;
            let mut all_zero = true;
            for i in 0..D {
                let d = (m % side) as i64 - k_i64;
                offset[i] = d;
                if d != 0 {
                    all_zero = false;
                }
                m /= side;
            }
            if all_zero {
                continue;
            }

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

        KRingIter {
            inner: neighbors.into_iter(),
        }
    }
}
