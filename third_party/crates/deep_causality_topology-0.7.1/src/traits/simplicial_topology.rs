/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the `SimplicialTopology` trait.
//!
//! The `SimplicialTopology` trait is designed for structures built upon
//! simplices, such as `SimplicialComplex` and `Manifold`. It provides
//! methods for querying properties related to simplices of various grades.

use crate::BaseTopology;
use crate::{Simplex, TopologyError};

/// A trait for topological structures composed of simplices.
///
/// Implementors of this trait represent simplicial complexes, providing
/// methods to query information about the simplices (vertices, edges, faces, etc.)
/// that constitute the complex. It extends `BaseTopology` to integrate with
/// general topological queries.
pub trait SimplicialTopology: BaseTopology {
    /// Returns the maximum topological dimension (grade) of any simplex present in the complex.
    ///
    /// For example, if the complex contains only vertices and edges, the maximum
    /// simplex dimension is 1. If it contains tetrahedrons, it's 3.
    ///
    /// # Mathematical Definition
    /// If $K$ is a simplicial complex, $\dim(K) = \max \{ \dim(\sigma) \mid \sigma \in K \}$.
    fn max_simplex_dimension(&self) -> usize;

    /// Returns the total number of simplices of a specific grade (dimension).
    ///
    /// # Arguments
    /// * `grade` - The topological grade (dimension) of the simplices to count.
    ///
    /// # Returns
    /// A `Result` which is:
    /// - `Ok(usize)` containing the count of simplices at the specified grade.
    /// - `Err(TopologyError)` if the `grade` is out of bounds or invalid for the complex.
    ///
    /// # Mathematical Definition
    /// For a simplicial complex $K$, this returns the cardinality of the set of
    /// $k$-simplices: $|\{ \sigma \in K \mid \dim(\sigma) = k \}|$.
    fn num_simplices_at_grade(&self, grade: usize) -> Result<usize, TopologyError>;

    /// Retrieves a reference to a simplex of a given grade and its canonical index.
    ///
    /// The canonical index usually refers to its position within an ordered list
    /// of all simplices of that grade (e.g., in a `Skeleton`).
    ///
    /// # Arguments
    /// * `grade` - The topological grade (dimension) of the simplex.
    /// * `index` - The canonical index of the simplex within its grade.
    ///
    /// # Returns
    /// A `Result` which is:
    /// - `Ok(&Simplex)` a reference to the requested simplex.
    /// - `Err(TopologyError)` if the `grade` or `index` is out of bounds.
    fn get_simplex(&self, grade: usize, index: usize) -> Result<&Simplex, TopologyError>;

    /// Checks if a given `Simplex` exists within the complex.
    ///
    /// The `grade` of the simplex is implicitly determined by its number of vertices.
    ///
    /// # Arguments
    /// * `simplex` - A reference to the `Simplex` to check for.
    ///
    /// # Returns
    /// `true` if the `simplex` is part of the complex, `false` otherwise.
    fn contains_simplex(&self, simplex: &Simplex) -> bool;
}
