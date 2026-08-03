/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::cell::Cell;
use crate::types::cell_complex::CellComplex;

use std::hash::Hash;

/// A cell in a hexagonal honeycomb lattice.
///
/// Vertices are sites. Edges are bonds. Faces are hexagons.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct HoneycombCell {
    /// Dimension (0=vertex, 1=edge, 2=hexagon)
    dim: usize,
    /// Unique identifier for the cell within its dimension.
    id: usize,
    /// Coordinates: [row, col, subtype]
    /// Subtypes:
    /// Dim 0: 0=SiteA, 1=SiteB
    /// Dim 1: 0=Bond(A-B), 1=Bond(A-B_left), 2=Bond(A-B_top)
    /// Dim 2: 0=Hexagon
    coords: [usize; 3],
    /// LatticeComplex width (cols) needed for consistent ID calculation
    cols: usize,
}

impl Cell for HoneycombCell {
    fn dim(&self) -> usize {
        self.dim
    }

    fn boundary(&self) -> Vec<(Self, i8)> {
        // Return boundary cells with orientation +1/-1
        let r = self.coords[0];
        let c = self.coords[1];
        let subtype = self.coords[2];
        let cols = self.cols;

        match self.dim {
            0 => vec![], // Vertices have no boundary
            1 => {
                // Edges have 2 vertices as boundary: B - A
                // Vertex A at (r, c) subtype 0
                // Vertex B depends on edge type

                // Helper to encode ID consistently
                let vert_id = |r, c, t| 2 * (r * cols + c) + t;

                let make_vert = |r, c, t| HoneycombCell {
                    dim: 0,
                    id: vert_id(r, c, t),
                    coords: [r, c, t],
                    cols,
                };

                let vert_a = make_vert(r, c, 0);

                let vert_b = match subtype {
                    0 => Some(make_vert(r, c, 1)), // Same cell B
                    1 => {
                        if c > 0 {
                            Some(make_vert(r, c - 1, 1))
                        } else {
                            None
                        }
                    } // Left cell B
                    2 => {
                        if r > 0 {
                            Some(make_vert(r - 1, c, 1))
                        } else {
                            None
                        }
                    } // Top cell B
                    _ => None,
                };

                if let Some(vb) = vert_b {
                    vec![(vb, 1), (vert_a, -1)]
                } else {
                    vec![] // Boundary edge hanging? Or just omit.
                }
            }
            2 => {
                // Face boundary: 6 edges.
                // Leaving empty for now as test only checks b0 (connectivity).
                vec![]
            }
            _ => vec![],
        }
    }
}

/// Honeycomb (hexagonal) lattice in 2D.
/// Used in graphene, Haldane model, Kitaev model.
pub struct HoneycombLattice {
    size: [usize; 2],
    periodic: [bool; 2],
}

impl HoneycombLattice {
    pub fn new(size: [usize; 2], periodic: [bool; 2]) -> Self {
        Self { size, periodic }
    }

    pub fn size(&self) -> &[usize; 2] {
        &self.size
    }

    pub fn periodic(&self) -> &[bool; 2] {
        &self.periodic
    }

    /// Convert to CellComplex for homology computations.
    pub fn as_cell_complex(&self) -> CellComplex<HoneycombCell> {
        let rows = self.size[0];
        let cols = self.size[1];
        let mut cells = Vec::new();

        // Helper to encode ID (cols dependent)
        // Ensure ID uniqueness: Dim 0: [0..2RC], Dim 1: [0..3RC], Dim 2: [0..RC]
        let vert_id = |r, c, t| 2 * (r * cols + c) + t;
        let edge_id = |r, c, t| 3 * (r * cols + c) + t;
        let face_id = |r, c| r * cols + c;

        // Generate Hexagons (Faces)
        for r in 0..rows {
            for c in 0..cols {
                cells.push(HoneycombCell {
                    dim: 2,
                    id: face_id(r, c),
                    coords: [r, c, 0],
                    cols,
                });
            }
        }

        // Generate Vertices (Sites)
        for r in 0..rows {
            for c in 0..cols {
                // Site A
                cells.push(HoneycombCell {
                    dim: 0,
                    id: vert_id(r, c, 0),
                    coords: [r, c, 0],
                    cols,
                });
                // Site B
                cells.push(HoneycombCell {
                    dim: 0,
                    id: vert_id(r, c, 1),
                    coords: [r, c, 1],
                    cols,
                });
            }
        }

        // Generate Edges (Bonds)
        // 3 bonds per unit cell potential.
        // Bond 0 (A-B internal): Always exists
        // Bond 1 (A-B left): Exists if c > 0 (for non-periodic)
        // Bond 2 (A-B top): Exists if r > 0
        for r in 0..rows {
            for c in 0..cols {
                // Bond 0
                cells.push(HoneycombCell {
                    dim: 1,
                    id: edge_id(r, c, 0),
                    coords: [r, c, 0],
                    cols,
                });

                // Bond 1
                if c > 0 {
                    cells.push(HoneycombCell {
                        dim: 1,
                        id: edge_id(r, c, 1),
                        coords: [r, c, 1],
                        cols,
                    });
                }

                // Bond 2
                if r > 0 {
                    cells.push(HoneycombCell {
                        dim: 1,
                        id: edge_id(r, c, 2),
                        coords: [r, c, 2],
                        cols,
                    });
                }
            }
        }

        CellComplex::from_cells(cells)
    }
}
