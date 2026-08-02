/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementations of MixedGraph edge mutation and orientation.

use crate::types::mixed_graph::canonical;
use crate::{Edge, Mark, MixedGraph, TopologyError};

impl<T> MixedGraph<T> {
    /// Validates that `idx` is an existing node index.
    pub(crate) fn check_node(&self, idx: usize) -> Result<(), TopologyError> {
        if idx >= self.num_vertices {
            return Err(TopologyError::IndexOutOfBounds(format!(
                "Node index {idx} out of bounds (num_vertices {})",
                self.num_vertices
            )));
        }
        Ok(())
    }

    /// CPU implementation of `add_edge`. Stores one canonical `Edge` for the
    /// unordered pair `{u, v}` with the given endpoint marks.
    pub(crate) fn add_edge_impl(
        &mut self,
        u: usize,
        v: usize,
        mark_u: Mark,
        mark_v: Mark,
    ) -> Result<(), TopologyError> {
        self.check_node(u)?;
        self.check_node(v)?;
        if u == v {
            return Err(TopologyError::GraphError(
                "self-loops are not allowed in a MixedGraph".to_string(),
            ));
        }
        let (key, u_is_lo) = canonical(u, v);
        if self.edges.contains_key(&key) {
            return Err(TopologyError::GraphError(format!(
                "an edge between {u} and {v} already exists; remove or reorient it instead"
            )));
        }
        let edge = if u_is_lo {
            Edge {
                lo: mark_u,
                hi: mark_v,
            }
        } else {
            Edge {
                lo: mark_v,
                hi: mark_u,
            }
        };
        self.edges.insert(key, edge);
        Ok(())
    }

    /// CPU implementation of `remove_edge`. Returns `true` if an edge was removed.
    pub(crate) fn remove_edge_impl(&mut self, u: usize, v: usize) -> Result<bool, TopologyError> {
        self.check_node(u)?;
        self.check_node(v)?;
        let (key, _) = canonical(u, v);
        Ok(self.edges.remove(&key).is_some())
    }

    /// CPU implementation of `set_endpoint`. Sets the mark at the `at` endpoint
    /// of the existing edge `{at, other}`.
    pub(crate) fn set_endpoint_impl(
        &mut self,
        at: usize,
        other: usize,
        mark: Mark,
    ) -> Result<(), TopologyError> {
        self.check_node(at)?;
        self.check_node(other)?;
        let (key, at_is_lo) = canonical(at, other);
        match self.edges.get_mut(&key) {
            Some(edge) => {
                if at_is_lo {
                    edge.lo = mark;
                } else {
                    edge.hi = mark;
                }
                Ok(())
            }
            None => Err(TopologyError::GraphError(format!(
                "no edge between {at} and {other} to orient"
            ))),
        }
    }

    /// CPU implementation of `orient`: turns an undirected `u — v` into `u → v`.
    pub(crate) fn orient_impl(&mut self, u: usize, v: usize) -> Result<(), TopologyError> {
        self.check_node(u)?;
        self.check_node(v)?;
        match self.edge_marks(u, v) {
            Some((Mark::Tail, Mark::Tail)) => self.set_endpoint_impl(v, u, Mark::Arrow),
            Some(_) => Err(TopologyError::GraphError(format!(
                "edge between {u} and {v} is not undirected"
            ))),
            None => Err(TopologyError::GraphError(format!(
                "no edge between {u} and {v} to orient"
            ))),
        }
    }

    /// Verifies the structural invariant: every stored key is canonical
    /// (`lo < hi`) and in range. The canonical-pair map guarantees a single
    /// edge per unordered pair by construction; this checks the keys directly.
    pub fn invariant_holds(&self) -> bool {
        self.edges
            .keys()
            .all(|&(a, b)| a < b && b < self.num_vertices)
    }
}
