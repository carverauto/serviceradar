/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the `ManifoldTopology` trait.
//!
//! The `ManifoldTopology` trait provides methods for structures that aspire to
//! be manifolds, allowing for validation of geometric and topological properties
//! that define a manifold.

use crate::SimplicialTopology;

/// A trait for structures capable of evaluating manifold-specific criteria.
///
/// This trait extends `SimplicialTopology`, providing a set of methods to
/// verify whether a given simplicial structure adheres to the strict
/// topological and geometric conditions required for it to be classified
/// as a manifold. These checks are crucial for applications in physics
/// and advanced geometry.
pub trait ManifoldTopology: SimplicialTopology {
    /// Checks if the structure satisfies the properties required to be an oriented manifold.
    ///
    /// # Mathematical Definition
    /// An $n$-manifold is orientable if it is possible to make a consistent choice
    /// of orientation for its tangent spaces at every point. For simplicial
    /// complexes, this translates to a consistent orientation of its simplices
    /// such that adjacent $n$-simplices induce opposite orientations on their common $(n-1)$-face.
    fn is_oriented(&self) -> bool;

    /// Checks if the local neighborhood around each point/simplex satisfies the link condition.
    ///
    /// The link condition is a combinatorial property that ensures local flatness
    /// in a simplicial complex, a necessary condition for it to be a topological manifold.
    ///
    /// # Mathematical Definition
    /// For a simplicial complex $K$ to be an $n$-manifold, the link of every vertex $v \in K$
    /// must be homeomorphic to an $(n-1)$-sphere (for an interior vertex) or an $(n-1)$-disk
    /// (for a boundary vertex). The link of a vertex $v$ is the set of all simplices $\sigma \in K$
    /// such that $\sigma \cap v = \emptyset$ and $\sigma * v \in K$, where $\sigma * v$ is the join.
    fn satisfies_link_condition(&self) -> bool;

    /// Computes the Euler characteristic of the structure.
    ///
    /// The Euler characteristic is a topological invariant, often denoted $\chi$.
    /// It can be used to classify manifolds and is related to properties like genus.
    ///
    /// # Mathematical Definition
    /// For a finite CW complex, the Euler characteristic is the alternating sum
    /// of the number of cells of each dimension: $\chi = \sum_{i=0}^n (-1)^i c_i$,
    /// where $c_i$ is the number of $i$-cells (simplices in this context).
    fn euler_characteristic(&self) -> isize;

    /// Checks if the manifold has a boundary.
    ///
    /// A manifold can be with or without boundary. Manifolds with boundary have
    /// "edges" or "surfaces" that form a lower-dimensional manifold.
    ///
    /// # Mathematical Definition
    /// The boundary of an $n$-manifold $M$, denoted $\partial M$, is an $(n-1)$-manifold
    /// without boundary. For a simplicial complex, the boundary is formed by $(n-1)$-faces
    /// that are contained in exactly one $n$-simplex.
    fn has_boundary(&self) -> bool;

    /// Performs all necessary checks to validate if the structure is a manifold.
    ///
    /// This method aggregates the results of other manifold-specific checks.
    ///
    /// # Returns
    /// `true` if all manifold criteria are met, `false` otherwise.
    fn is_manifold(&self) -> bool {
        self.is_oriented() && self.satisfies_link_condition() && !self.has_boundary() /* ... and potentially other checks */
    }
}
