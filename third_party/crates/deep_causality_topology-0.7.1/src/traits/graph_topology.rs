/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the `GraphTopology` trait.
//!
//! The `GraphTopology` trait captures behaviors common to structures that can be
//! interpreted as graphs, featuring nodes (vertices) and connections (edges).
//! This allows for generic algorithms that operate on graph-theoretic properties.

use crate::BaseTopology;
use crate::TopologyError;

/// A trait for topological structures that exhibit graph-like properties.
///
/// Implementors of this trait represent structures composed of nodes (vertices)
/// and their pairwise connections (edges). This trait extends `BaseTopology`
/// and provides methods for querying graph-specific properties such as
/// the number of nodes and edges, existence of nodes, and retrieving neighbors.
pub trait GraphTopology: BaseTopology {
    /// Returns the total number of nodes (vertices) in the graph-like structure.
    ///
    /// # Mathematical Definition
    /// For a graph $G = (V, E)$, this method returns $|V|$, the cardinality of the
    /// set of vertices.
    fn num_nodes(&self) -> usize;

    /// Returns the total number of edges or primary connections in the graph-like structure.
    ///
    /// # Mathematical Definition
    /// For a graph $G = (V, E)$, this method returns $|E|$, the cardinality of the
    /// set of edges.
    fn num_edges(&self) -> usize;

    /// Checks if a node with the given identifier exists in the graph-like structure.
    ///
    /// # Arguments
    /// * `node_id` - A `usize` identifier for the node.
    ///
    /// # Returns
    /// `true` if the node exists, `false` otherwise.
    fn has_node(&self, node_id: usize) -> bool;

    /// Retrieves a list of identifiers for nodes directly connected to the specified node.
    ///
    /// # Arguments
    /// * `node_id` - A `usize` identifier for the central node.
    ///
    /// # Returns
    /// A `Result` which is:
    /// - `Ok(Vec<usize>)` containing the identifiers of neighboring nodes if `node_id` is valid.
    /// - `Err(TopologyError)` if the `node_id` is out of bounds or invalid for the structure.
    ///
    /// # Mathematical Definition
    /// For a node $v \in V$, this returns the set of all $u \in V$ such that
    /// $(v, u) \in E$ (for a directed graph) or $\{v, u\} \in E$ (for an undirected graph).
    /// It represents the set of nodes adjacent to $v$.
    fn get_neighbors(&self, node_id: usize) -> Result<Vec<usize>, TopologyError>;
}
