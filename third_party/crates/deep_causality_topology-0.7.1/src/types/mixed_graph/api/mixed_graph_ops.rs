/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Edge-mutation and orientation API for MixedGraph.

use crate::{Mark, MixedGraph, TopologyError};

impl<T> MixedGraph<T> {
    /// Adds an edge between `u` and `v` with the given endpoint marks
    /// (`mark_u` at `u`, `mark_v` at `v`).
    ///
    /// # Errors
    /// * `IndexOutOfBounds` if a node is out of range.
    /// * `GraphError` if `u == v`, or if an edge already exists for the pair
    ///   (remove or reorient it instead).
    pub fn add_edge(
        &mut self,
        u: usize,
        v: usize,
        mark_u: Mark,
        mark_v: Mark,
    ) -> Result<(), TopologyError> {
        self.add_edge_impl(u, v, mark_u, mark_v)
    }

    /// Adds a directed arc `u → v` (`Tail` at `u`, `Arrow` at `v`).
    pub fn add_arc(&mut self, u: usize, v: usize) -> Result<(), TopologyError> {
        self.add_edge_impl(u, v, Mark::Tail, Mark::Arrow)
    }

    /// Adds an undirected edge `u — v` (`Tail` at both endpoints).
    pub fn add_undirected(&mut self, u: usize, v: usize) -> Result<(), TopologyError> {
        self.add_edge_impl(u, v, Mark::Tail, Mark::Tail)
    }

    /// Adds a bidirected edge `u ↔ v` (`Arrow` at both endpoints).
    pub fn add_bidirected(&mut self, u: usize, v: usize) -> Result<(), TopologyError> {
        self.add_edge_impl(u, v, Mark::Arrow, Mark::Arrow)
    }

    /// Removes any edge between `u` and `v`. Returns `true` if one was removed.
    pub fn remove_edge(&mut self, u: usize, v: usize) -> Result<bool, TopologyError> {
        self.remove_edge_impl(u, v)
    }

    /// Sets the endpoint mark at node `at` of the existing edge `{at, other}`.
    ///
    /// This is the general PAG orientation primitive: any endpoint can be set to
    /// any [`Mark`]. Returns a `GraphError` if no edge exists for the pair.
    pub fn set_endpoint(
        &mut self,
        at: usize,
        other: usize,
        mark: Mark,
    ) -> Result<(), TopologyError> {
        self.set_endpoint_impl(at, other, mark)
    }

    /// Orients an existing undirected edge `u — v` into the directed arc `u → v`.
    ///
    /// Returns a `GraphError` if the pair has no edge or is not undirected.
    pub fn orient(&mut self, u: usize, v: usize) -> Result<(), TopologyError> {
        self.orient_impl(u, v)
    }
}
