/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::cell::Cell;

/// A k-cell in a D-dimensional regular lattice.
///
/// A lattice is a regular CW complex where all k-cells are hypercubes.
/// Each cell is identified by its base vertex coordinates and an orientation mask
/// indicating which dimensions it extends into.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct LatticeCell<const D: usize> {
    /// Base vertex position [x₀, x₁, ..., x_{D-1}]
    /// For a k-cell extending in dimension i, the vertex coordinate is the lower bound.
    pub position: [usize; D],

    /// Orientation mask: bit i set means cell extends in dimension i.
    /// The dimension k of the cell is the population count of this mask.
    pub orientation: u32,
}

impl<const D: usize> LatticeCell<D> {
    // --- Constructors ---

    /// Create a new cell at the given position with orientation mask.
    pub fn new(position: [usize; D], orientation: u32) -> Self {
        Self {
            position,
            orientation,
        }
    }

    /// Create a vertex (0-cell) at the given position.
    pub fn vertex(position: [usize; D]) -> Self {
        Self::new(position, 0)
    }

    /// Create an edge (1-cell) at position extending in dimension `dir`.
    pub fn edge(position: [usize; D], dir: usize) -> Self {
        debug_assert!(dir < D, "Direction must be less than D");
        Self::new(position, 1 << dir)
    }

    // --- Getters ---

    /// Base vertex position.
    pub fn position(&self) -> &[usize; D] {
        &self.position
    }

    /// Orientation bitmask.
    pub fn orientation(&self) -> u32 {
        self.orientation
    }

    /// The dimension k of this cell.
    pub fn cell_dim(&self) -> usize {
        self.orientation.count_ones() as usize
    }

    // --- Predicates ---

    /// Is this a vertex (0-cell)?
    pub fn is_vertex(&self) -> bool {
        self.orientation == 0
    }

    /// Is this an edge (1-cell)?
    pub fn is_edge(&self) -> bool {
        self.orientation.count_ones() == 1
    }

    /// Is this a face (2-cell)?
    pub fn is_face(&self) -> bool {
        self.orientation.count_ones() == 2
    }

    // --- Operations ---

    /// Get the vertices of this cell.
    /// A k-cell is a hypercube with 2^k vertices.
    pub fn vertices(&self) -> Vec<[usize; D]> {
        let k = self.cell_dim();
        let num_vertices = 1 << k;
        let mut vertices = Vec::with_capacity(num_vertices);

        // Find which dimensions are active
        let mut active_dims = Vec::with_capacity(k);
        for i in 0..D {
            if (self.orientation & (1 << i)) != 0 {
                active_dims.push(i);
            }
        }

        // Iterate through all 2^k combinations
        for i in 0..num_vertices {
            let mut pos = self.position;
            for (bit_idx, &dim) in active_dims.iter().enumerate() {
                if (i & (1 << bit_idx)) != 0 {
                    pos[dim] += 1;
                }
            }
            vertices.push(pos);
        }

        vertices
    }
}

// Marker traits
unsafe impl<const D: usize> Send for LatticeCell<D> {}
unsafe impl<const D: usize> Sync for LatticeCell<D> {}

impl<const D: usize> Cell for LatticeCell<D> {
    fn dim(&self) -> usize {
        self.cell_dim()
    }

    fn boundary(&self) -> Vec<(Self, i8)> {
        // The boundary of a k-cube consists of 2k (k-1)-faces.
        // For each active dimension i, there is a "back" face (at x_i) and "front" face (at x_i + 1).

        let mut chain = Vec::new();

        if self.is_vertex() {
            return chain;
        }

        let mut dim_idx = 0; // The index of the active dimension among active dimensions (0..k-1)

        for i in 0..D {
            if (self.orientation & (1 << i)) != 0 {
                // This is an active dimension.
                // The (k-1)-cell with this dimension removed.
                let sub_orientation = self.orientation & !(1 << i);

                // Sign: (-1)^dim_idx
                let sign = if dim_idx % 2 == 0 { 1 } else { -1 };

                let back_cell = LatticeCell::new(self.position, sub_orientation);

                let mut front_pos = self.position;
                front_pos[i] += 1;
                let front_cell = LatticeCell::new(front_pos, sub_orientation);

                // Front face: sign
                chain.push((front_cell, sign));
                // Back face: -sign
                chain.push((back_cell, -sign));

                dim_idx += 1;
            }
        }

        chain
    }
}
