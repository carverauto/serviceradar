/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Mixed graph with typed edge endpoints.
//!
//! A [`MixedGraph`] carries a [`Mark`] at each endpoint of every edge, so a
//! single type expresses directed, undirected, bidirected, and partially
//! directed edges — and therefore DAGs, CPDAGs, MAGs, and PAGs. Edges are stored
//! in a canonical-pair map keyed by `(min(u, v), max(u, v))`, so there is exactly
//! one entry per unordered pair: the endpoint invariant (at most one edge per
//! pair, with consistent marks) is enforced structurally and cannot drift.

use deep_causality_tensor::CausalTensor;
use std::collections::BTreeMap;

mod acyclicity;
mod api;
mod clone;
mod constructors;
mod display;
mod getters;
mod mixed_graph_ops;
mod queries;
mod topology;

/// The mark at one endpoint of an edge, in the typed-endpoint calculus shared by
/// CPDAGs, MAGs, and PAGs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Mark {
    /// A plain tail `—` (no arrowhead).
    Tail,
    /// An arrowhead `>`.
    Arrow,
    /// A circle `∘` (orientation unknown), used by PAGs.
    Circle,
}

/// An edge between two nodes, recording the endpoint mark at the lower-indexed
/// node (`lo`) and the higher-indexed node (`hi`).
///
/// The `(lo, hi)` pair names the edge kind; see [`Edge::kind`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Edge {
    /// Mark at the lower-indexed endpoint.
    pub lo: Mark,
    /// Mark at the higher-indexed endpoint.
    pub hi: Mark,
}

/// The classification of an edge by its (order-independent) pair of endpoint marks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EdgeKind {
    /// `—` directed: one tail, one arrowhead (`u → v`).
    Directed,
    /// `——` undirected: two tails (`u — v`).
    Undirected,
    /// `↔` bidirected: two arrowheads (`u ↔ v`).
    Bidirected,
    /// `∘→` partially directed: one circle, one arrowhead.
    PartiallyDirected,
    /// `∘—∘` nondirected: two circles.
    Nondirected,
    /// `∘—` partially undirected: one circle, one tail.
    PartiallyUndirected,
}

impl Edge {
    /// Classifies the edge by its unordered pair of endpoint marks.
    pub fn kind(&self) -> EdgeKind {
        use Mark::{Arrow, Circle, Tail};
        match (self.lo, self.hi) {
            (Tail, Tail) => EdgeKind::Undirected,
            (Arrow, Arrow) => EdgeKind::Bidirected,
            (Circle, Circle) => EdgeKind::Nondirected,
            (Tail, Arrow) | (Arrow, Tail) => EdgeKind::Directed,
            (Circle, Arrow) | (Arrow, Circle) => EdgeKind::PartiallyDirected,
            (Circle, Tail) | (Tail, Circle) => EdgeKind::PartiallyUndirected,
        }
    }
}

/// A mixed graph over `num_vertices` nodes with typed edge endpoints.
///
/// Nodes are `usize` indices; `data` carries an optional per-node payload (`T`)
/// and `cursor` is the comonadic focus, mirroring [`crate::Graph`] and
/// [`crate::Hypergraph`]. Edges live in `edges`, keyed by the canonical pair.
#[derive(Debug, Clone, PartialEq)]
pub struct MixedGraph<T> {
    /// Number of vertices.
    pub(crate) num_vertices: usize,
    /// Edge map keyed by the canonical pair `(min(u, v), max(u, v))`.
    pub(crate) edges: BTreeMap<(usize, usize), Edge>,
    /// Per-node payload data.
    pub(crate) data: CausalTensor<T>,
    /// Comonadic focus (cursor) node index.
    pub(crate) cursor: usize,
}

/// Returns the canonical key for an unordered pair and whether `u` is the
/// lower-indexed endpoint (`true`) or the higher-indexed one (`false`).
#[inline]
pub(crate) fn canonical(u: usize, v: usize) -> ((usize, usize), bool) {
    if u <= v {
        ((u, v), true)
    } else {
        ((v, u), false)
    }
}
