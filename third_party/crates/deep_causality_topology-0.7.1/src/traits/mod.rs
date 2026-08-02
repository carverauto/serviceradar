/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the core trait hierarchy for topological structures within
//! the `deep_causality_topology` crate.
//!
//! The trait structure is designed to provide a robust, extensible, and semantically rich API,
//! allowing for generic programming over various topological types while enabling specialized
//! implementations where necessary. It follows a hierarchical design, starting from the most
//! fundamental properties and progressively adding more specific topological and geometric
//! characteristics.
//!
//! # Trait Hierarchy Overview
//!
//! *   **[`BaseTopology`]**: The foundational trait for any topological structure. It defines
//!     universal properties such as `dimension`, `len` (number of primary elements), and
//!     `num_elements_at_grade`. All other topology-specific traits build upon this.
//!
//! *   **[`GraphTopology`]**: Extends `BaseTopology` for structures interpretable as graphs.
//!     It provides methods to query graph-theoretic properties like `num_nodes`, `num_edges`,
//!     and `get_neighbors`.
//!
//! *   **[`HypergraphTopology`]**: Builds upon `GraphTopology` for structures where connections
//!     (hyperedges) can involve an arbitrary number of nodes. It adds methods such as
//!     `num_hyperedges`, `nodes_in_hyperedge`, and `hyperedges_on_node`.
//!
//! *   **[`SimplicialTopology`]**: Extends `BaseTopology` for structures composed of simplices,
//!     like simplicial complexes. It offers methods to query properties of simplices at
//!     different grades, such as `max_simplex_dimension`, `num_simplices_at_grade`,
//!     `get_simplex`, and `contains_simplex`.
//!
//! *   **[`ManifoldTopology`]**: Extends `SimplicialTopology` for structures that aim to be
//!     manifolds. It includes methods for validating manifold-specific geometric and
//!     topological criteria, such as `is_oriented`, `satisfies_link_condition`,
//!     `euler_characteristic`, and `has_boundary`.
//!
//! This modular trait design promotes code reusability, clear separation of concerns,
//! and facilitates the implementation of generic algorithms that can operate on
//! different levels of topological abstraction.
//!

pub mod base_topology;
pub mod cell;
pub mod chain_complex;
pub mod gauge_group;
pub mod graph_topology;
pub mod has_hodge_star;
pub mod hypergraph_topology;
pub mod manifold_topology;
pub mod mixed_graph_topology;
pub mod neighborhood;
pub mod simplicial_topology;
