/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the foundational `BaseTopology` trait.
//!
//! The `BaseTopology` trait provides the most generic properties applicable
//! to any topological structure, regardless of its specific type (e.g.,
//! point cloud, graph, simplicial complex). It establishes fundamental
//! queries such as dimension, size, and element count per grade.

/// A foundational trait for any topological structure.
///
/// This trait establishes a common interface for basic topological queries,
/// enabling generic programming across diverse topological data structures
/// like point clouds, graphs, simplicial complexes, and manifolds.
pub trait BaseTopology {
    /// Returns the primary topological dimension of the structure.
    ///
    /// For a `PointCloud`, this is typically 0 (representing points).
    /// For a `Graph`, this is typically 1 (representing edges/connections).
    /// For a `k`-simplex within a `SimplicialComplex`, this would be `k`.
    ///
    /// # Mathematical Definition
    /// In topology, the dimension of a space intuitively refers to the number of
    /// independent parameters needed to specify any point within that space.
    /// For discrete structures, this usually corresponds to the highest dimension
    /// of its constituent elementary cells (e.g., vertices (0D), edges (1D), faces (2D)).
    fn dimension(&self) -> usize;

    /// Returns the total number of fundamental elements in the topological structure.
    ///
    /// This count refers to the primary building blocks of the specific topology.
    /// For a `PointCloud`, it's the number of points.
    /// For a `Graph`, it's often the number of nodes (vertices).
    /// For a `SimplicialComplex`, it might represent the total count of all simplices
    /// across all grades, or specifically the number of 0-simplices (vertices).
    /// The exact interpretation may vary slightly per concrete implementation but
    /// should represent the "size" of the structure.
    ///
    /// # Mathematical Definition
    /// Analogous to the cardinality of the set of fundamental building blocks of the structure.
    fn len(&self) -> usize;

    /// Returns `true` if the topological structure contains no fundamental elements.
    ///
    /// This is a convenience method, equivalent to `self.len() == 0`.
    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns the number of elements at a specific grade (dimension).
    ///
    /// This method is particularly useful for graded structures like
    /// `SimplicialComplex` which contain elements of different dimensions
    /// (e.g., 0-simplices (vertices), 1-simplices (edges), 2-simplices (faces)).
    ///
    /// For structures like `PointCloud` (conceptually a 0-complex) or
    /// `Graph` (conceptually a 1-complex), this might only return a
    /// meaningful value for their inherent primary dimension.
    ///
    /// # Arguments
    /// * `grade` - The topological grade (dimension) of the elements to count.
    ///
    /// # Returns
    /// An `Option<usize>` containing the count of elements at the specified grade,
    /// or `None` if the grade is not applicable or out of bounds for the structure.
    ///
    /// # Mathematical Definition
    /// For a cellular complex $K$, $N_k = |\{ \sigma \in K \mid \dim(\sigma) = k \}|$
    /// represents the number of $k$-dimensional cells (elements) in the complex.
    fn num_elements_at_grade(&self, grade: usize) -> Option<usize>;
}
