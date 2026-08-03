/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the `HypergraphTopology` trait.
//!
//! The `HypergraphTopology` trait extends `GraphTopology` to include features
//! specific to hypergraphs, where connections (hyperedges) can involve more
//! than two nodes.

use crate::GraphTopology;
use crate::TopologyError;

/// A trait for topological structures that exhibit hypergraph-like properties.
///
/// Implementors of this trait represent hypergraphs, where hyperedges can connect
/// an arbitrary number of nodes. It extends `GraphTopology` by adding methods
/// to query hyperedge-specific information.
pub trait HypergraphTopology: GraphTopology {
    /// Returns the total number of hyperedges in the hypergraph structure.
    ///
    /// # Mathematical Definition
    /// For a hypergraph $H = (V, E)$, this method returns $|E|$, the cardinality of the
    /// set of hyperedges. A hyperedge $e \in E$ is a subset of vertices $V$.
    fn num_hyperedges(&self) -> usize;

    /// Retrieves a list of identifiers for nodes that are part of the specified hyperedge.
    ///
    /// # Arguments
    /// * `hyperedge_id` - A `usize` identifier for the hyperedge.
    ///
    /// # Returns
    /// A `Result` which is:
    /// - `Ok(Vec<usize>)` containing the identifiers of nodes within the hyperedge if `hyperedge_id` is valid.
    /// - `Err(TopologyError)` if the `hyperedge_id` is out of bounds or invalid for the structure.
    ///
    /// # Mathematical Definition
    /// For a hyperedge $e_j \in E$, this returns the set of vertices $V_j \subseteq V$
    /// that constitute $e_j$.
    fn nodes_in_hyperedge(&self, hyperedge_id: usize) -> Result<Vec<usize>, TopologyError>;

    /// Retrieves a list of identifiers for hyperedges that contain the specified node.
    ///
    /// # Arguments
    /// * `node_id` - A `usize` identifier for the node.
    ///
    /// # Returns
    /// A `Result` which is:
    /// - `Ok(Vec<usize>)` containing the identifiers of hyperedges connected to the node if `node_id` is valid.
    /// - `Err(TopologyError)` if the `node_id` is out of bounds or invalid for the structure.
    ///
    /// # Mathematical Definition
    /// For a node $v_i \in V$, this returns the set of all hyperedges $E_i \subseteq E$
    /// such that $v_i \in e_j$ for each $e_j \in E_i$.
    fn hyperedges_on_node(&self, node_id: usize) -> Result<Vec<usize>, TopologyError>;
}
