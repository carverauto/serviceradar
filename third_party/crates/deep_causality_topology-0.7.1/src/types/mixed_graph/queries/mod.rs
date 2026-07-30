/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Structural queries over a MixedGraph: the directed-arc projection (parents,
//! children), undirected neighbors, adjacency, and edge enumeration by kind.

use crate::{EdgeKind, Mark, MixedGraph};

impl<T> MixedGraph<T> {
    /// Yields `(other, mark_at_v, mark_at_other)` for every edge incident to `v`.
    fn incident(&self, v: usize) -> impl Iterator<Item = (usize, Mark, Mark)> + '_ {
        self.edges.iter().filter_map(move |(&(a, b), e)| {
            if a == v {
                Some((b, e.lo, e.hi))
            } else if b == v {
                Some((a, e.hi, e.lo))
            } else {
                None
            }
        })
    }

    /// Returns the parents of `v` in the directed-arc projection — every `u`
    /// with a directed arc `u → v` (`Tail` at `u`, `Arrow` at `v`). Ascending.
    pub fn parents(&self, v: usize) -> Vec<usize> {
        let mut out: Vec<usize> = self
            .incident(v)
            .filter(|&(_, m_v, m_other)| m_other == Mark::Tail && m_v == Mark::Arrow)
            .map(|(other, _, _)| other)
            .collect();
        out.sort_unstable();
        out
    }

    /// Returns the children of `v` in the directed-arc projection — every `u`
    /// with a directed arc `v → u` (`Tail` at `v`, `Arrow` at `u`). Ascending.
    pub fn children(&self, v: usize) -> Vec<usize> {
        let mut out: Vec<usize> = self
            .incident(v)
            .filter(|&(_, m_v, m_other)| m_v == Mark::Tail && m_other == Mark::Arrow)
            .map(|(other, _, _)| other)
            .collect();
        out.sort_unstable();
        out
    }

    /// Returns the undirected neighbors of `v` — every `u` with `u — v`
    /// (`Tail` at both endpoints). Ascending.
    pub fn undirected_neighbors(&self, v: usize) -> Vec<usize> {
        let mut out: Vec<usize> = self
            .incident(v)
            .filter(|&(_, m_v, m_other)| m_v == Mark::Tail && m_other == Mark::Tail)
            .map(|(other, _, _)| other)
            .collect();
        out.sort_unstable();
        out
    }

    /// Returns `true` if `u` and `v` are joined by an edge of any kind.
    pub fn is_adjacent(&self, u: usize, v: usize) -> bool {
        self.has_edge(u, v)
    }

    /// Returns every directed arc as an ordered `(parent, child)` pair. Ascending
    /// by parent then child.
    pub fn arcs(&self) -> Vec<(usize, usize)> {
        let mut out: Vec<(usize, usize)> = self
            .edges
            .iter()
            .filter_map(|(&(a, b), e)| match (e.lo, e.hi) {
                (Mark::Tail, Mark::Arrow) => Some((a, b)),
                (Mark::Arrow, Mark::Tail) => Some((b, a)),
                _ => None,
            })
            .collect();
        out.sort_unstable();
        out
    }

    /// Returns the canonical `(min, max)` pairs of every edge of `kind`.
    pub fn edges_of_kind(&self, kind: EdgeKind) -> Vec<(usize, usize)> {
        self.edges
            .iter()
            .filter(|(_, e)| e.kind() == kind)
            .map(|(&pair, _)| pair)
            .collect()
    }

    /// Returns the canonical `(min, max)` pairs of every undirected edge.
    pub fn undirected_edges(&self) -> Vec<(usize, usize)> {
        self.edges_of_kind(EdgeKind::Undirected)
    }
}
