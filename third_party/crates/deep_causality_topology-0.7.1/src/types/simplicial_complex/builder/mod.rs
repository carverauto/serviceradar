/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Builder implementations for SimplicialComplex.

use std::collections::HashMap;

use deep_causality_sparse::CsrMatrix;

use crate::{Simplex, SimplicialComplex, Skeleton, TopologyError};

/// A builder for constructing `SimplicialComplex` instances incrementally.
///
/// This builder manages the consistent addition of simplices, ensures that ALL
/// faces of an added simplex are also present (closure property), and computes
/// the necessary boundary and coboundary operators automatically upon build.
///
/// # Example
/// ```rust
/// use deep_causality_topology::{Simplex, SimplicialComplexBuilder};
///
/// let mut builder = SimplicialComplexBuilder::new(2);
/// // Add a triangle (and implicitly its edges and vertices)
/// builder.add_simplex(Simplex::new(vec![0, 1, 2])).expect("Failed to add simplex");
///
/// let complex = builder.build::<f64>().expect("Failed to build complex");
/// assert_eq!(complex.max_simplex_dimension(), 2);
/// ```
pub struct SimplicialComplexBuilder {
    dim: usize,
    // Grade -> List of Simplices
    simplices: Vec<Vec<Simplex>>,
    // Grade -> Map<Simplex, Index>
    indices: Vec<HashMap<Simplex, usize>>,
}

impl SimplicialComplexBuilder {
    /// Creates a new `SimplicialComplexBuilder` with a fixed maximum dimension.
    ///
    /// # Arguments
    /// * `dim` - The maximum dimension (grade) of simplices this complex will store.
    pub fn new(dim: usize) -> Self {
        let mut simplices = Vec::with_capacity(dim + 1);
        let mut indices = Vec::with_capacity(dim + 1);
        for _ in 0..=dim {
            simplices.push(Vec::new());
            indices.push(HashMap::new());
        }
        Self {
            dim,
            simplices,
            indices,
        }
    }

    /// Adds a simplex to the complex.
    ///
    /// This method recursively ensures that all lower-dimensional faces of the
    /// provided simplex are also added to the complex, maintaining the simplicial
    /// complex property (if a simplex is in K, all its faces are in K).
    ///
    /// # Arguments
    /// * `s` - The `Simplex` to add.
    ///
    /// # Returns
    /// * `Ok(())` if successful.
    /// * `Err(TopologyError)` if the simplex dimension exceeds the builder's maximum dimension.
    pub fn add_simplex(&mut self, s: Simplex) -> Result<(), TopologyError> {
        let grade = s.vertices().len().checked_sub(1).ok_or_else(|| {
            TopologyError::InvalidInput("Cannot add empty simplex (0 vertices)".to_string())
        })?;

        if grade > self.dim {
            return Err(TopologyError::DimensionMismatch(format!(
                "Simplex dimension {} exceeds complex dimension {}",
                grade, self.dim
            )));
        }

        // Check/Add existence
        if !self.indices[grade].contains_key(&s) {
            let idx = self.simplices[grade].len();
            self.simplices[grade].push(s.clone());
            self.indices[grade].insert(s.clone(), idx);

            // Recursively add boundaries if grade > 0
            if grade > 0 {
                let faces = self.get_faces(&s);
                for face in faces {
                    self.add_simplex(face)?;
                }
            }
        }

        Ok(())
    }

    /// Helper to generate (n-1)-faces of an n-simplex.
    fn get_faces(&self, s: &Simplex) -> Vec<Simplex> {
        let n = s.vertices().len();
        let mut faces = Vec::with_capacity(n);
        for i in 0..n {
            let mut verts = s.vertices().clone();
            verts.remove(i);
            // Simplex::new sorts vertices, so faces are canonical
            faces.push(Simplex::new(verts));
        }
        faces
    }

    /// Consumes the builder and produces a `SimplicialComplex`.
    ///
    /// This process involves:
    /// 1. Sorting simplices at each grade to ensure canonical indexing (required for `BinarySearch`).
    /// 2. Constructing `Skeleton` objects for each grade.
    /// 3. Computing Boundary Operators (∂) as sparse matrices.
    /// 4. Computing Coboundary Operators as the transpose of boundary operators.
    ///
    /// # Returns
    /// * `Ok(SimplicialComplex)` on success.
    /// * `Err(TopologyError)` on internal inconsistency (unlikely if add_simplex logic holds).
    pub fn build<T>(mut self) -> Result<SimplicialComplex<T>, TopologyError> {
        // Step 1: Sort simplices in each grade.
        // This is crucial because Skeleton::get_index relies on binary_search,
        // which requires sorted data.
        for g in 0..=self.dim {
            self.simplices[g].sort();
            self.indices[g].clear();
            for (idx, s) in self.simplices[g].iter().enumerate() {
                self.indices[g].insert(s.clone(), idx);
            }
        }

        let mut skeletons = Vec::with_capacity(self.dim + 1);
        let mut boundaries = Vec::with_capacity(self.dim);
        let mut coboundaries = Vec::with_capacity(self.dim);

        // Construct skeletons
        for (g, s_list) in self.simplices.iter().enumerate() {
            skeletons.push(Skeleton::new(g, s_list.clone()));
        }

        // Construct operators
        for k in 0..self.dim {
            // Map (k+1)-chains to k-chains.
            // Rows = |C_k|, Cols = |C_{k+1}|
            let rows = self.simplices[k].len();
            let cols = self.simplices[k + 1].len();

            let mut triplets = Vec::new();

            for (col_idx, simplex_kp1) in self.simplices[k + 1].iter().enumerate() {
                // Decompose into k-faces
                let faces = self.get_faces(simplex_kp1);
                for (i, face) in faces.iter().enumerate() {
                    // Find row index
                    if let Some(&row_idx) = self.indices[k].get(face) {
                        // Standard orientation: (-1)^i
                        let sign = if i % 2 == 0 { 1i8 } else { -1i8 };
                        triplets.push((row_idx, col_idx, sign));
                    } else {
                        // This should theoretically not happen if `add_simplex` works correctly
                        // and enforced closure.
                        return Err(TopologyError::SimplexNotFound());
                    }
                }
            }

            let b = CsrMatrix::from_triplets(rows, cols, &triplets)
                .map_err(|e| TopologyError::InvalidInput(e.to_string()))?;

            // Coboundary is transpose
            let cb = b.transpose();

            boundaries.push(b);
            coboundaries.push(cb);
        }

        Ok(SimplicialComplex::new(
            skeletons,
            boundaries,
            coboundaries,
            Vec::new(),
        ))
    }
}
