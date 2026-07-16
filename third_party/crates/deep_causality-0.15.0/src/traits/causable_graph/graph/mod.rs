/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::errors::{CausalGraphIndexError, CausalityGraphError};
use crate::traits::causable_graph::CausalGraph;
use ultragraph::{PathfindingGraphAlgorithms, TopologicalGraphAlgorithms};

pub trait CausableGraph<T>
where
    T: Clone,
{
    fn is_frozen(&self) -> bool;

    /// Ensures the graph is in the immutable, performance-optimized `Static` state.
    ///
    /// If the graph is already frozen, this operation is a no-op. Otherwise, it
    /// converts the graph from a `Dynamic` state in-place. This is an O(V + E)
    /// operation if a state change occurs.
    fn freeze(&mut self);

    /// Ensures the graph is in the mutable, `Dynamic` state.
    ///
    /// If the graph is already dynamic, this operation is a no-op. Otherwise, it
    /// converts the graph from a `Static` state in-place. This is an O(V + E)
    /// operation if a state change occurs and requires node and edge data to be `Clone`.
    fn unfreeze(&mut self);

    /// Freezes the graph for reasoning **only if it is acyclic** (a directed acyclic graph).
    ///
    /// This is the opt-in, DAG-enforcing counterpart to [`freeze`](Self::freeze). Where
    /// `freeze` transitions the graph to its static reasoning form *unconditionally* and
    /// therefore accepts cyclic structures, `freeze_dag` additionally verifies that the
    /// graph contains no directed cycle, providing a structural guarantee for callers that
    /// require one.
    ///
    /// Cycle detection requires the static representation, so this method freezes first and
    /// then checks. On success the graph is left frozen and ready for reasoning; on failure
    /// it is rolled back to the dynamic state, so a graph is never left presented as a
    /// frozen, cyclic graph.
    ///
    /// # Returns
    ///
    /// * `Ok(())` if the graph is acyclic. The graph is left frozen.
    /// * `Err(CausalityGraphError)` if the graph contains a directed cycle. The graph is left unfrozen.
    fn freeze_dag(&mut self) -> Result<(), CausalityGraphError> {
        // `has_cycle` is only available on the static (frozen) representation, so freeze first.
        self.freeze();

        // After freezing, the static cycle check (Kahn's algorithm) is total: it returns
        // `Ok(false)` for a DAG and `Ok(true)` for a cycle, and cannot report "not frozen".
        // The `unwrap_or(true)` default for the (here unreachable) error variant keeps the
        // contract simple — `Ok` always means "frozen DAG" — by never certifying a graph we
        // could not verify.
        if self.get_graph().has_cycle().unwrap_or(true) {
            // Roll back so the graph is not left in a frozen, cyclic state.
            self.unfreeze();
            return Err(CausalityGraphError(
                "Graph contains a directed cycle and cannot be frozen as a DAG".to_string(),
            ));
        }

        Ok(())
    }

    /// Freezes the graph with the full Stage-4 precondition checks: acyclicity
    /// ([`freeze_dag`](Self::freeze_dag)) plus the **single-writer invariant** at reconvergent
    /// joins — the structural preconditions the schedule-invariance theorem
    /// (`core.causaloid.graph_fold_order_invariant`) assumes.
    ///
    /// # Single-writer invariant
    ///
    /// State is never merged at a join (the per-channel ruling): at most one incoming branch of a
    /// join may write state. Because a stored causal function is opaque, writers are **declared**:
    /// `state_writers` lists the node indices whose causal functions write the state channel. Each
    /// index must name an existing node (`< number_nodes`); an out-of-range declaration fails the
    /// freeze rather than being silently ignored. For
    /// every join (a node with two or more incoming edges), a writer counts against an incoming
    /// branch when it lies in that branch's ancestor cone but not in every branch's cone — a
    /// writer *above the fork* is seen identically by all branches and cannot conflict. Two or
    /// more branches with exclusive writers is a violation: the freeze fails, naming the join,
    /// and the graph is rolled back to the dynamic state.
    ///
    /// # Returns
    ///
    /// * `Ok(())` — the graph is frozen, acyclic, and single-writer clean.
    /// * `Err(CausalityGraphError)` — a check failed; the graph is left unfrozen.
    fn freeze_verified(&mut self, state_writers: &[usize]) -> Result<(), CausalityGraphError>
    where
        Self: Sized,
    {
        self.freeze_verified_with_check(state_writers, |_| Ok(()))
    }

    /// [`freeze_verified`](Self::freeze_verified) with a **level-specific hook** — the extension
    /// point for stack-level structural checks (e.g. the quantum layer's commuting-factorization
    /// check; the QCM-on-EPP freeze model). The hook runs after the built-in checks pass, on the
    /// frozen graph; a hook error rolls the graph back to the dynamic state.
    fn freeze_verified_with_check<F>(
        &mut self,
        state_writers: &[usize],
        level_check: F,
    ) -> Result<(), CausalityGraphError>
    where
        F: Fn(&Self) -> Result<(), CausalityGraphError>,
        Self: Sized,
    {
        // Check 1: acyclicity (freezes on success, rolls back on failure).
        self.freeze_dag()?;

        // Check 2: single-writer at every reconvergent join.
        if let Err(e) = self.check_single_writer(state_writers) {
            self.unfreeze();
            return Err(e);
        }

        // Check 3: the level-specific hook.
        if let Err(e) = level_check(self) {
            self.unfreeze();
            return Err(e);
        }

        Ok(())
    }

    /// The single-writer check on the frozen graph (see
    /// [`freeze_verified`](Self::freeze_verified)). Split out so hooks and tests can run it
    /// directly.
    fn check_single_writer(&self, state_writers: &[usize]) -> Result<(), CausalityGraphError> {
        use ultragraph::GraphTraversal;

        if state_writers.is_empty() {
            return Ok(());
        }

        let n_nodes = self.number_nodes();

        // `state_writers` is caller-supplied. An index at or beyond the node count names no node in
        // the graph, so it can never match any `w` in `0..n_nodes` below and would be silently
        // dropped — letting the freeze appear to satisfy a writer declaration it never applied.
        // Reject the malformed input instead of ignoring it.
        if let Some(&bad) = state_writers.iter().find(|&&w| w >= n_nodes) {
            return Err(CausalityGraphError(format!(
                "Invalid state-writer index {bad}: the graph has {n_nodes} node(s), so valid \
                 writer indices are 0..{n_nodes}. Declared writers: {state_writers:?}."
            )));
        }

        let is_writer = |idx: usize| state_writers.contains(&idx);

        // The ancestor cone of `start`, inclusive.
        let cone = |start: usize| -> Vec<bool> {
            let mut seen = vec![false; n_nodes];
            seen[start] = true;
            let mut stack = vec![start];
            while let Some(node) = stack.pop() {
                if let Ok(parents) = self.get_graph().inbound_edges(node) {
                    for p in parents {
                        if !seen[p] {
                            seen[p] = true;
                            stack.push(p);
                        }
                    }
                }
            }
            seen
        };

        for join in 0..n_nodes {
            let parents: Vec<usize> = match self.get_graph().inbound_edges(join) {
                Ok(it) => it.collect(),
                Err(_) => continue,
            };
            if parents.len() < 2 {
                continue;
            }

            let cones: Vec<Vec<bool>> = parents.iter().map(|&p| cone(p)).collect();
            // A writer above the fork (in every branch cone) cannot conflict; a branch counts
            // as writing when it has a writer exclusive to it.
            let writing_branches = cones
                .iter()
                .filter(|c| {
                    (0..n_nodes)
                        .any(|w| c[w] && is_writer(w) && !cones.iter().all(|other| other[w]))
                })
                .count();
            if writing_branches >= 2 {
                return Err(CausalityGraphError(format!(
                    "Single-writer violation at join node {join}: {writing_branches} incoming \
                     branches carry exclusive state-writers (declared writers: {state_writers:?}). \
                     State is never merged at a reconvergent join — restructure so at most one \
                     branch writes state (core.causaloid.graph_fold_order_invariant precondition)."
                )));
            }
        }

        Ok(())
    }

    /// Returns a reference to the underlying `CausalGraph`.
    ///
    /// This method is primarily used to enable default implementations for
    /// other traits like `CausableGraphExplaining` and `CausableGraphReasoning`,
    /// allowing them to operate directly on the graph structure.
    fn get_graph(&self) -> &CausalGraph<T>;

    /// Adds a special "root" causaloid to the graph.
    ///
    /// The root node serves as the starting point for causal reasoning and traversals.
    /// There can typically only be one root node in the graph.
    ///
    /// # Arguments
    ///
    /// * `value` - The causaloid of type `T` to be added as the root.
    ///
    /// # Returns
    ///
    /// The `usize` index of the newly added root node.
    fn add_root_causaloid(&mut self, value: T) -> Result<usize, CausalityGraphError>;

    /// Checks if a root causaloid has been set in the graph.
    ///
    /// # Returns
    ///
    /// * `true` if a root node exists, `false` otherwise.
    fn contains_root_causaloid(&self) -> bool;

    /// Retrieves an immutable reference to the root causaloid, if it exists.
    ///
    /// # Returns
    ///
    /// * `Some(&T)` containing a reference to the root causaloid if it's present.
    /// * `None` if no root node has been added to the graph.
    fn get_root_causaloid(&self) -> Option<&T>;

    /// Retrieves the index of the root causaloid, if it exists.
    ///
    /// # Returns
    ///
    /// * `Some(usize)` containing the index of the root node if it's present.
    /// * `None` if no root node has been added to the graph.
    fn get_root_index(&self) -> Option<usize>;

    /// Gets the index of the last causaloid added to the graph.
    ///
    /// This is useful for understanding the current size or for linking
    /// to a newly added node.
    ///
    /// # Returns
    ///
    /// * `Ok(usize)` containing the index of the last node.
    /// * `Err(CausalityGraphError)` if the graph is empty and has no nodes.
    fn get_last_index(&self) -> Result<usize, CausalityGraphError>;

    // Nodes
    /// Adds a new causaloid (node) to the graph.
    ///
    /// # Arguments
    ///
    /// * `value` - The causaloid of type `T` to be added to the graph.
    ///
    /// # Returns
    ///
    /// The `usize` index of the newly added causaloid.
    fn add_causaloid(&mut self, value: T) -> Result<usize, CausalityGraphError>;

    /// Checks if a causaloid exists at a specific index in the graph.
    ///
    /// # Arguments
    ///
    /// * `index` - The `usize` index to check for the existence of a causaloid.
    ///
    /// # Returns
    ///
    /// * `true` if a causaloid is present at the given index.
    /// * `false` if the index is out of bounds or no causaloid is at that index.
    fn contains_causaloid(&self, index: usize) -> bool;

    /// Retrieves an immutable reference to a causaloid at a given index.
    ///
    /// # Arguments
    ///
    /// * `index` - The `usize` index of the causaloid to retrieve.
    ///
    /// # Returns
    ///
    /// * `Some(&T)` containing a reference to the causaloid if it exists at the specified index.
    /// * `None` if the index is out of bounds.
    fn get_causaloid(&self, index: usize) -> Option<&T>;

    /// Removes a causaloid from the graph at the specified index.
    ///
    /// Note: Removing a causaloid will also remove all edges connected to it.
    ///
    /// # Arguments
    ///
    /// * `index` - The `usize` index of the causaloid to remove.
    ///
    /// # Returns
    ///
    /// * `Ok(())` if the causaloid was successfully removed.
    /// * `Err(CausalGraphIndexError)` if the provided `index` is invalid or out of bounds.
    fn remove_causaloid(&mut self, index: usize) -> Result<(), CausalGraphIndexError>;

    // Edges
    /// Adds a directed edge between two causaloids in the graph.
    ///
    /// This creates a causal link from the causaloid at index `a` to the one at index `b`.
    ///
    /// # Arguments
    ///
    /// * `a` - The `usize` index of the source causaloid (the cause).
    /// * `b` - The `usize` index of the target causaloid (the effect).
    ///
    /// # Returns
    ///
    /// * `Ok(())` if the edge was successfully added.
    /// * `Err(CausalGraphIndexError)` if either `a` or `b` is an invalid index.
    fn add_edge(&mut self, a: usize, b: usize) -> Result<(), CausalGraphIndexError>;

    /// Adds a weighted directed edge between two causaloids.
    ///
    /// The weight can represent the strength, probability, or intensity of the causal relationship.
    ///
    /// # Arguments
    ///
    /// * `a` - The `usize` index of the source causaloid.
    /// * `b` - The `usize` index of the target causaloid.
    /// * `weight` - The `u64` weight of the edge.
    ///
    /// # Returns
    ///
    /// * `Ok(())` if the weighted edge was successfully added.
    /// * `Err(CausalGraphIndexError)` if either `a` or `b` is an invalid index.
    fn add_edg_with_weight(
        &mut self,
        a: usize,
        b: usize,
        weight: u64,
    ) -> Result<(), CausalGraphIndexError>;

    /// Checks if a directed edge exists from causaloid `a` to causaloid `b`.
    ///
    /// # Arguments
    ///
    /// * `a` - The `usize` index of the source causaloid.
    /// * `b` - The `usize` index of the target causaloid.
    ///
    /// # Returns
    ///
    /// * `true` if a directed edge from `a` to `b` exists.
    /// * `false` if no such edge exists or if either index is invalid.
    fn contains_edge(&self, a: usize, b: usize) -> bool;

    /// Removes a directed edge between two causaloids.
    ///
    /// If multiple edges exist between `a` and `b`, this will remove one of them.
    ///
    /// # Arguments
    ///
    /// * `a` - The `usize` index of the source causaloid.
    /// * `b` - The `usize` index of the target causaloid.
    ///
    /// # Returns
    ///
    /// * `Ok(())` if the edge was successfully removed.
    /// * `Err(CausalGraphIndexError)` if the edge does not exist or if either index is invalid.
    fn remove_edge(&mut self, a: usize, b: usize) -> Result<(), CausalGraphIndexError>;

    /// Returns the total number of causaloids (nodes) in the graph.
    ///
    /// # Returns
    ///
    /// A `usize` representing the total count of nodes in the graph.
    fn size(&self) -> usize;

    /// Checks if the graph contains no causaloids.
    ///
    /// # Returns
    ///
    /// * `true` if the graph has no nodes.
    /// * `false` if the graph has one or more nodes.
    fn is_empty(&self) -> bool;

    /// Removes all causaloids and edges from the graph.
    ///
    /// After calling this method, the graph will be empty.
    fn clear(&mut self);

    /// Returns the total number of edges in the graph.
    ///
    /// # Returns
    ///
    /// A `usize` representing the total count of edges.
    fn number_edges(&self) -> usize;

    /// Returns the total number of causaloids (nodes) in the graph.
    ///
    /// # Returns
    ///
    /// A `usize` representing the total count of nodes.
    fn number_nodes(&self) -> usize;

    /// Default implementation for shortest path algorithm.
    ///
    /// Finds the shortest path between two node indices in the graph.
    ///
    /// start_index: The start node index
    /// stop_index: The target node index
    ///
    /// Returns:
    /// - Ok(`Vec<usize>`): The node indices of the shortest path
    /// - Err(CausalityGraphError): If no path exists
    ///
    /// Checks if start and stop nodes are identical and early returns error.
    /// Otherwise calls shortest_path() on the underlying CausalGraph.
    ///
    fn get_shortest_path(
        &self,
        start_index: usize,
        stop_index: usize,
    ) -> Result<Vec<usize>, CausalityGraphError> {
        if start_index == stop_index {
            return Err(CausalityGraphError(
                "Start and Stop node identical: No shortest path possible".into(),
            ));
        }

        match self.get_graph().shortest_path(start_index, stop_index) {
            Ok(path) => match path {
                Some(path) => Ok(path),
                None => Err(CausalityGraphError("No path found".to_string())),
            },
            Err(e) => Err(CausalityGraphError(format!("{e}"))),
        }
    }
}
