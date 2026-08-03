/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Getter methods for MixedGraph fields and edge queries.

use crate::types::mixed_graph::canonical;
use crate::{Edge, EdgeKind, Mark, MixedGraph};
use deep_causality_tensor::CausalTensor;
use std::collections::BTreeMap;

impl<T> MixedGraph<T> {
    /// Returns the number of vertices.
    pub fn num_vertices(&self) -> usize {
        self.num_vertices
    }

    /// Returns the total number of edges (of any kind).
    pub fn num_edges(&self) -> usize {
        self.edges.len()
    }

    /// Returns a reference to the canonical-pair edge map.
    pub fn edges(&self) -> &BTreeMap<(usize, usize), Edge> {
        &self.edges
    }

    /// Returns a reference to the per-node payload tensor.
    pub fn data(&self) -> &CausalTensor<T> {
        &self.data
    }

    /// Returns the current cursor (comonadic focus) position.
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    /// Returns `true` if any edge exists between `u` and `v`.
    pub fn has_edge(&self, u: usize, v: usize) -> bool {
        let (key, _) = canonical(u, v);
        self.edges.contains_key(&key)
    }

    /// Returns the endpoint marks of the edge between `u` and `v` in the query
    /// order `(mark at u, mark at v)`, or `None` if no edge exists.
    pub fn edge_marks(&self, u: usize, v: usize) -> Option<(Mark, Mark)> {
        let (key, u_is_lo) = canonical(u, v);
        self.edges
            .get(&key)
            .map(|e| if u_is_lo { (e.lo, e.hi) } else { (e.hi, e.lo) })
    }

    /// Returns the mark at the `at` endpoint of the edge `{at, other}`, or
    /// `None` if no edge exists.
    pub fn endpoint_mark(&self, at: usize, other: usize) -> Option<Mark> {
        self.edge_marks(at, other).map(|(m_at, _)| m_at)
    }

    /// Returns the classification of the edge between `u` and `v`, or `None`.
    pub fn edge_kind(&self, u: usize, v: usize) -> Option<EdgeKind> {
        let (key, _) = canonical(u, v);
        self.edges.get(&key).map(Edge::kind)
    }

    /// Counts the edges of a given [`EdgeKind`].
    pub fn count_of_kind(&self, kind: EdgeKind) -> usize {
        self.edges.values().filter(|e| e.kind() == kind).count()
    }
}
