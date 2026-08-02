/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Acyclicity and topological order over the **directed-arc projection** of a
//! MixedGraph. Undirected, bidirected, and partially directed edges are ignored;
//! only `(Tail, Arrow)` arcs participate.
//!
//! Implemented self-contained (Kahn for the order, DFS for cycle reporting) so
//! the type carries no dependency on an external graph engine.

use crate::MixedGraph;
use std::cmp::Reverse;
use std::collections::BinaryHeap;

impl<T> MixedGraph<T> {
    /// Builds the child-adjacency and in-degree of the directed-arc projection.
    fn arc_adjacency(&self) -> (Vec<Vec<usize>>, Vec<usize>) {
        let n = self.num_vertices;
        let mut children = vec![Vec::new(); n];
        let mut indeg = vec![0usize; n];
        for (parent, child) in self.arcs() {
            children[parent].push(child);
            indeg[child] += 1;
        }
        (children, indeg)
    }

    /// Returns a topological order of the directed-arc projection (smallest-index
    /// first among ready nodes, for determinism), or `None` if the projection
    /// contains a directed cycle. Every node — including those touched only by
    /// undirected edges or none at all — appears in the order when it exists.
    pub fn topological_sort(&self) -> Option<Vec<usize>> {
        let n = self.num_vertices;
        let (children, mut indeg) = self.arc_adjacency();

        let mut ready: BinaryHeap<Reverse<usize>> =
            (0..n).filter(|&v| indeg[v] == 0).map(Reverse).collect();

        let mut order = Vec::with_capacity(n);
        while let Some(Reverse(v)) = ready.pop() {
            order.push(v);
            for &c in &children[v] {
                indeg[c] -= 1;
                if indeg[c] == 0 {
                    ready.push(Reverse(c));
                }
            }
        }

        if order.len() == n { Some(order) } else { None }
    }

    /// Returns `true` if the directed-arc projection contains a directed cycle.
    pub fn has_cycle(&self) -> bool {
        self.topological_sort().is_none()
    }

    /// Returns the nodes of one directed cycle in the arc projection (in cycle
    /// order), or `None` if the projection is acyclic.
    ///
    /// Uses an explicit-stack DFS (not recursion) so that a long directed chain
    /// cannot overflow the call stack.
    pub fn find_cycle(&self) -> Option<Vec<usize>> {
        let n = self.num_vertices;
        let (children, _) = self.arc_adjacency();
        // 0 = unvisited, 1 = on the current DFS path, 2 = fully explored.
        let mut color = vec![0u8; n];
        // Explicit DFS stack of `(node, next-child-index)`. Its nodes are exactly
        // the current path, so a back edge's cycle is read straight off it.
        let mut stack: Vec<(usize, usize)> = Vec::new();

        for start in 0..n {
            if color[start] != 0 {
                continue;
            }
            color[start] = 1;
            stack.push((start, 0));

            while let Some(&(v, ci)) = stack.last() {
                if ci == children[v].len() {
                    color[v] = 2;
                    stack.pop();
                    continue;
                }
                stack.last_mut().unwrap().1 = ci + 1;
                let c = children[v][ci];
                match color[c] {
                    // Back edge: the cycle is the path from the first occurrence of `c`.
                    1 => {
                        let from = stack.iter().position(|&(x, _)| x == c).unwrap();
                        return Some(stack[from..].iter().map(|&(x, _)| x).collect());
                    }
                    0 => {
                        color[c] = 1;
                        stack.push((c, 0));
                    }
                    _ => {} // fully explored: not on the current path, skip.
                }
            }
        }
        None
    }
}
