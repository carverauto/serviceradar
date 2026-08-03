/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the `MixedGraphTopology` trait.
//!
//! The `MixedGraphTopology` trait extends `GraphTopology` for graphs whose edges
//! carry a mark at each endpoint, so directed arcs and undirected (and, for PAGs,
//! bidirected and partially directed) edges coexist. It adds queries over the
//! directed-arc projection and the undirected overlay.

use crate::GraphTopology;
use crate::TopologyError;

/// A trait for graph-like structures with typed edge endpoints (CPDAG/MAG/PAG).
///
/// Extends [`GraphTopology`] — where `get_neighbors` spans every edge kind — with
/// projection-specific queries: the parents of a node over the directed-arc
/// projection and its undirected neighbors, plus counts by projection.
pub trait MixedGraphTopology: GraphTopology {
    /// Returns the number of directed arcs (`Tail`–`Arrow` edges).
    fn num_arcs(&self) -> usize;

    /// Returns the number of undirected edges (`Tail`–`Tail`).
    fn num_undirected_edges(&self) -> usize;

    /// Returns the parents of `node_id` over the directed-arc projection — the
    /// nodes `u` with an arc `u → node_id`.
    ///
    /// # Errors
    /// `Err(TopologyError)` if `node_id` is out of bounds.
    fn get_parents(&self, node_id: usize) -> Result<Vec<usize>, TopologyError>;

    /// Returns the undirected neighbors of `node_id` — the nodes joined to it by
    /// an undirected edge.
    ///
    /// # Errors
    /// `Err(TopologyError)` if `node_id` is out of bounds.
    fn get_undirected_neighbors(&self, node_id: usize) -> Result<Vec<usize>, TopologyError>;
}
