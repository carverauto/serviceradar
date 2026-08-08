/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Cell-volume computation for `CubicalReggeGeometry<D, R>` — Phase R1.
//!
//! On a cubical lattice every k-cell is axis-aligned, so its k-volume is the product of the
//! k edge lengths meeting at its base vertex. This module dispatches on the four edge-length
//! uniformity levels (`UnitEdge`, `Uniform`, `PerAxis`, `PerEdge`) to evaluate that product
//! at the lowest cost the level allows.
//!
//! See `openspec/changes/add-cubical-regge-calculus-core/tasks.md` §2 and
//! `openspec/notes/CubicalReggeCalculus.md` §3.R1.

use super::{CubicalReggeGeometry, EdgeLengths, SignatureMarker};
use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use deep_causality_algebra::RealField;
impl<const D: usize, R: RealField, S: SignatureMarker> CubicalReggeGeometry<D, R, S> {
    /// k-volume of a single lattice cell, where `k = cell.cell_dim()`.
    ///
    /// For a k-cube with active dimensions `{i₁, …, iₖ}` (bits set in `cell.orientation()`),
    /// the volume is the product of the k edge lengths along those axes meeting at
    /// `cell.position()`. Returns `R::one()` for 0-cells (vertices) — the empty product.
    ///
    /// The per-edge arm reads each contributing edge length via
    /// `LatticeComplex::edge_index`. This relies on cubical cells being axis-aligned, so
    /// the Gram-matrix cross-terms vanish and the determinant collapses to the product.
    /// A sheared cubical representation would need a different routine; this one is
    /// guarded by a debug assertion.
    pub fn cell_volume(&self, complex: &LatticeComplex<D, R>, cell: &LatticeCell<D>) -> R {
        let orientation = cell.orientation();
        let grade = orientation.count_ones() as usize;

        match &self.edge_lengths {
            EdgeLengths::UnitEdge => R::one(),
            EdgeLengths::Uniform { length } => {
                let mut v = R::one();
                for _ in 0..grade {
                    v *= *length;
                }
                v
            }
            EdgeLengths::PerAxis { lengths } => {
                let mut v = R::one();
                for (axis, length) in lengths.iter().enumerate() {
                    if (orientation & (1 << axis)) != 0 {
                        v *= *length;
                    }
                }
                v
            }
            EdgeLengths::PerEdge { lengths } => {
                // PerEdge stores one length per lattice edge. The cubical formula assumes
                // axis-aligned cells so the Gram-matrix cross-terms vanish and the
                // determinant collapses to a product of edge lengths. The current PerEdge
                // representation cannot express off-diagonal Gram entries, but a future
                // sheared-cubical extension would need a different routine entirely.
                debug_assert!(
                    !lengths.is_empty(),
                    "PerEdge edge-length buffer is empty; cell_volume cannot be computed.",
                );
                let position = *cell.position();
                let mut v = R::one();
                for axis in 0..D {
                    if (orientation & (1 << axis)) != 0 {
                        let idx = complex.edge_index(position, axis);
                        v *= lengths[idx];
                    }
                }
                v
            }
        }
    }

    /// D-volume of a top-dimensional cube. Convenience wrapper around `cell_volume` that
    /// debug-asserts the cell is in fact D-dimensional.
    pub fn top_cell_volume(&self, complex: &LatticeComplex<D, R>, cell: &LatticeCell<D>) -> R {
        debug_assert_eq!(
            cell.cell_dim(),
            D,
            "top_cell_volume requires a D-cell (got grade {})",
            cell.cell_dim(),
        );
        self.cell_volume(complex, cell)
    }
}
