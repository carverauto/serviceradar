/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod stateful;

use crate::*;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Debug;
use ultragraph::{GraphTraversal, TopologicalGraphAlgorithms};

/// The relay-termination bound: the maximum number of adaptive-reasoning (`RelayTo`) rounds one
/// graph evaluation may compose.
///
/// Each relay re-enters the graph with a **runtime-produced** program, so no structural measure on
/// the graph bounds the loop — two causaloids relaying to each other would otherwise run forever.
/// The fuel bound makes the relay handler **total**: exhaustion is reported as a loud error
/// (preserving state, context, and logs), never looped. Fuel only cuts divergence — an evaluation
/// that finishes within the bound is unaffected (fuel monotonicity). Machine-checked model:
/// `core.causal_effect.relay_termination` in `lean/DeepCausalityFormal/Core/CausalEffect.lean`;
/// closes the relay-termination item of
/// `openspec/notes/causal-algebra/algebraic-causaloid-assumptions.md` #2 Q3.
pub const MAX_RELAY_ROUNDS: usize = 1024;

/// Provides default implementations for monadic reasoning over `CausableGraph` items.
///
/// Any graph type that implements `CausableGraph<T>` where `T` is `MonadicCausable<I, O>`
/// will automatically gain a suite of useful default methods for monadic evaluation.
/// Provides default implementations for monadic reasoning over `CausableGraph` items.
///
/// Any graph type that implements `CausableGraph<T>` where `T` is `MonadicCausable<V, V>`
/// will automatically gain a suite of useful default methods for monadic evaluation.
pub trait MonadicCausableGraphReasoning<V, PS, C>: CausableGraph<Causaloid<V, V, PS, C>>
where
    V: Verdict + Default + Clone + Send + Sync + 'static + Debug,
    PS: Default + Clone + Send + Sync + 'static,
    C: Clone + Send + Sync + 'static,
    Causaloid<V, V, PS, C>: MonadicCausable<V, V>,
{
    /// Evaluates a single, specific causaloid within the graph by its index using a monadic approach.
    ///
    /// This is a convenience method that locates the causaloid and calls its `evaluate` method.
    ///
    /// # Arguments
    ///
    /// * `index` - The index of the causaloid to evaluate.
    /// * `effect` - The runtime effect to be passed to the node's evaluation function.
    ///
    /// # Returns
    ///
    /// The `PropagatingEffect` from the evaluated causaloid, or a `PropagatingEffect` containing
    /// a `CausalityError` if the node is not found or the evaluation fails.
    fn evaluate_single_cause(
        &self,
        index: usize,
        effect: &PropagatingEffect<V>,
    ) -> PropagatingEffect<V> {
        if !self.is_frozen() {
            return PropagatingEffect::from_error(CausalityError(CausalityErrorEnum::Custom(
                "Graph is not frozen. Call freeze() first".into(),
            )));
        }

        let causaloid = match self.get_causaloid(index) {
            Some(c) => c,
            None => {
                return PropagatingEffect::from_error(CausalityError(CausalityErrorEnum::Custom(
                    format!("Causaloid with index {index} not found in graph"),
                )));
            }
        };

        causaloid.evaluate(effect)
    }

    /// Reasons over the acyclic sub-DAG reachable from a start index using a monadic approach.
    ///
    /// The frozen graph must be acyclic. Evaluation runs a Kahn-style topological schedule rather
    /// than a breadth-first walk. A ready-set (a `BTreeSet` ordered by ascending node index) holds
    /// the nodes whose reachable parents have all resolved. The scheduler pops the lowest-index
    /// ready node, evaluates it once, and publishes its output effect to the wire slot of every
    /// reachable child. A child becomes ready when its last pending wire resolves.
    ///
    /// A reachability pre-pass first marks the start node and its descendants. A wire from a
    /// non-descendant is therefore resolved `Inactive` up front and never counted as pending, which
    /// keeps mid-graph starts and abandoned relay cones free of deadlock. A node reached by a single
    /// fired parent passes that parent's effect through, because the join of one input is the
    /// identity. A node reached by two or more fired parents is a reconvergence; converging values
    /// merge as `∇ ∘ (Λ₁ ⊗ Λ₂)` — the commutative `∇ = Verdict::join` with the identity Λ on every
    /// edge (this method takes no decorations; see
    /// [`evaluate_subgraph_from_cause_with_lambda_edges`](Self::evaluate_subgraph_from_cause_with_lambda_edges)).
    /// Machine-checked schedule invariance: `core.causaloid.graph_fold_order_invariant`
    /// (`lean/DeepCausalityFormal/Core/GraphAlgebra.lean`).
    ///
    /// ## Acyclicity requirement
    ///
    /// A directed cycle is rejected with an error before any node runs. A Kahn-style ready-set would
    /// otherwise silently skip the nodes trapped inside the cycle, so the frozen graph must be a DAG.
    ///
    /// ## Adaptive reasoning
    ///
    /// A `RelayTo(target, sub)` result ends the current round and starts a fresh round at `target`,
    /// seeded with the command's sub-program. Rounds compose sequentially. The abandoned cone of the
    /// relaying round simply stops and resolves `Inactive` implicitly. The relay is single-level.
    ///
    /// # Arguments
    ///
    /// * `start_index` - The index of the node to start evaluation from.
    /// * `initial_effect` - The initial runtime effect passed to the starting node's evaluation function.
    ///
    /// # Returns
    ///
    /// A `PropagatingEffect` carrying the effect of the last node processed under the ascending-index
    /// schedule. The first node error short-circuits the whole traversal and is returned with its
    /// logs intact.
    fn evaluate_subgraph_from_cause(
        &self,
        start_index: usize,
        initial_effect: &PropagatingEffect<V>,
    ) -> PropagatingEffect<V> {
        // No decorations: every edge is the identity Λ, so the join is the plain ∇-merge.
        self.evaluate_subgraph_from_cause_with_lambda_edges(
            start_index,
            initial_effect,
            &LambdaEdges::new(),
        )
    }

    /// [`evaluate_subgraph_from_cause`](Self::evaluate_subgraph_from_cause) with per-edge Λ
    /// decoration slots: the value flowing along a decorated edge is transformed by that edge's Λ
    /// (keyed by intrinsic `(source, target)` identity, never by order; absent slot = identity)
    /// before any join, so a reconvergent join computes `∇(Λ₁(a), Λ₂(b))` — Hardy's connection
    /// data on the edges, the commutative fuse at the node (`core.causaloid.inversion`,
    /// `core.causaloid.graph_fold_order_invariant`).
    ///
    /// Per-channel join policy (the reconvergence merge): the **value** channel folds
    /// `∇ = Verdict::join` over the Λ-transformed present values of the fired parents (all-absent
    /// ⇒ absence propagates); the **log** channel concatenates the fired parents' logs in
    /// ascending parent-index order (a canonical representative of the multiset-at-join ruling);
    /// the **state** channel never merges (single-writer invariant, checked at freeze —
    /// [`freeze_verified`](crate::CausableGraph::freeze_verified)). An erroring parent
    /// short-circuits before any join is reached.
    fn evaluate_subgraph_from_cause_with_lambda_edges(
        &self,
        start_index: usize,
        initial_effect: &PropagatingEffect<V>,
        lambda_edges: &LambdaEdges<V>,
    ) -> PropagatingEffect<V> {
        if !self.is_frozen() {
            return PropagatingEffect::from_error(CausalityError(CausalityErrorEnum::Custom(
                "Graph is not frozen. Call freeze() first".into(),
            )));
        }

        if !self.contains_causaloid(start_index) {
            return PropagatingEffect::from_error(CausalityError(CausalityErrorEnum::Custom(
                format!("Graph does not contain start causaloid with index {start_index}"),
            )));
        }

        // The classical fan-in evaluator requires a topological order, so the frozen graph must be
        // acyclic. A Kahn-style ready-set would otherwise silently skip nodes inside a cycle.
        if self.get_graph().has_cycle().unwrap_or(true) {
            return PropagatingEffect::from_error(CausalityError(CausalityErrorEnum::Custom(
                "Graph contains a directed cycle; the reconvergence-join evaluator requires an \
                 acyclic (frozen DAG) graph"
                    .into(),
            )));
        }

        let n_nodes = self.number_nodes();

        // Evaluation composes rounds sequentially: a round folds the reachable acyclic sub-DAG with
        // labeled fan-in; a `RelayTo` ends the round and starts a fresh one at the relay target with
        // the command's sub-program as the new seed (sequential composition of rounds).
        let mut round_start = start_index;
        let mut round_input = initial_effect.clone();
        // Relay fuel: bounds the number of relay rounds so the handler is total (see
        // `MAX_RELAY_ROUNDS` / `core.causal_effect.relay_termination`).
        let mut relay_rounds_left: usize = MAX_RELAY_ROUNDS;

        'rounds: loop {
            // Reachability pre-pass: only `round_start` and its descendants can fire. Every in-wire
            // from a non-descendant is thereby resolved `Inactive` up front (it is never counted in
            // `pending`), which is what keeps mid-graph starts and abandoned relay cones deadlock-free.
            let mut reachable = vec![false; n_nodes];
            reachable[round_start] = true;
            let mut stack = vec![round_start];
            while let Some(node) = stack.pop() {
                if let Ok(children) = self.get_graph().outbound_edges(node) {
                    for c in children {
                        if !reachable[c] {
                            reachable[c] = true;
                            stack.push(c);
                        }
                    }
                }
            }

            // Wire-slot bookkeeping. `pending[n]` counts the *reachable* parents of `n` not yet
            // resolved; a wire from an unreachable parent is pre-resolved `Inactive` (not counted).
            // `fired[n]` accumulates the effects of parents that fired, keyed by parent node index.
            let mut pending = vec![0usize; n_nodes];
            let mut fired: Vec<BTreeMap<usize, PropagatingEffect<V>>> =
                (0..n_nodes).map(|_| BTreeMap::new()).collect();
            let mut processed = vec![false; n_nodes];

            for node in 0..n_nodes {
                // The start node is seeded, so its parents are ignored (pending stays 0).
                if !reachable[node] || node == round_start {
                    continue;
                }
                if let Ok(parents) = self.get_graph().inbound_edges(node) {
                    pending[node] = parents.filter(|p| reachable[*p]).count();
                }
            }

            // Ready set ordered by ascending node index — the canonical schedule.
            let mut ready: BTreeSet<usize> = BTreeSet::new();
            ready.insert(round_start);

            let mut last_effect = round_input.clone();

            while let Some(node) = ready.pop_first() {
                if processed[node] {
                    continue;
                }
                processed[node] = true;

                // Resolve this node's incoming effect from its wire slots.
                let incoming = if node == round_start {
                    round_input.clone()
                } else {
                    let parents = std::mem::take(&mut fired[node]);
                    match parents.len() {
                        0 => {
                            // Unreachable invariant guard. The reachability pre-pass prunes dead paths
                            // at the wire level: an in-wire from a non-descendant of the start is never
                            // counted in `pending`, and every *reachable* ancestor of a node fires
                            // (induction from the seeded start over the acyclic reachable sub-DAG). So a
                            // non-start node that becomes ready always has at least one fired parent;
                            // it never resolves to a zero-parent join.
                            return PropagatingEffect::from_error(CausalityError(
                                CausalityErrorEnum::Custom(format!(
                                    "internal invariant: node {node} became ready with no fired parents"
                                )),
                            ));
                        }
                        1 => {
                            // Join of one fired parent is the identity fuse; the edge's Λ (if
                            // decorated) still applies — Λ is connection data, independent of
                            // fan-in. With no decoration the effect passes through unchanged.
                            let (parent_idx, effect) =
                                parents.into_iter().next().expect("len == 1");
                            match lambda_edges.get(parent_idx, node) {
                                None => effect,
                                Some(lambda) => {
                                    let (outcome, state, context, logs) = effect.into_parts();
                                    let transformed = match outcome {
                                        Ok(ce) => Ok(match ce.into_value() {
                                            Some(v) => CausalEffect::value(lambda(v)),
                                            None => CausalEffect::none(),
                                        }),
                                        Err(e) => Err(e),
                                    };
                                    PropagatingEffect::new(transformed, state, context, logs)
                                }
                            }
                        }
                        _ => {
                            // Reconvergence: `join = ∇ ∘ (Λ₁ ⊗ Λ₂)`. Each fired parent's value is
                            // transformed by its edge's Λ (keyed by intrinsic edge identity), then
                            // fused by the commutative `∇ = Verdict::join` — so the result is
                            // invariant under every schedule consistent with the causal order
                            // (`core.causaloid.graph_fold_order_invariant`; closes tracker #2 Q1).
                            // Logs concatenate in ascending parent-index order (the canonical
                            // representative of the multiset-at-join ruling); parents carrying no
                            // value (absence of evidence) contribute nothing to the fuse, and if
                            // no parent carries a value the absence propagates. Errors cannot
                            // reach a join (an erroring node short-circuits the traversal), and
                            // state never merges (single-writer, checked at freeze).
                            let mut merged_logs = EffectLog::new();
                            let mut merged_value: Option<V> = None;
                            for (parent_idx, effect) in parents {
                                let (outcome, _state, _context, mut logs) = effect.into_parts();
                                merged_logs.append(&mut logs);
                                if let Some(v) = outcome.ok().and_then(CausalEffect::into_value) {
                                    let v = lambda_edges.apply(parent_idx, node, v);
                                    merged_value = Some(match merged_value {
                                        None => v,
                                        Some(acc) => acc.join(v),
                                    });
                                }
                            }
                            let merged = match merged_value {
                                Some(v) => CausalEffect::value(v),
                                None => CausalEffect::none(),
                            };
                            PropagatingEffect::new(Ok(merged), (), None, merged_logs)
                        }
                    }
                };

                let causaloid = match self.get_causaloid(node) {
                    Some(c) => c,
                    None => {
                        return PropagatingEffect::from_error(CausalityError(
                            CausalityErrorEnum::Custom(format!(
                                "Failed to get causaloid at index {node}"
                            )),
                        ));
                    }
                };

                let result_effect = causaloid.evaluate(&incoming);
                last_effect = result_effect.clone();

                // A node error short-circuits the whole traversal (left-zero), preserving logs.
                if result_effect.is_err() {
                    return result_effect;
                }

                match result_effect.command_target() {
                    // Adaptive reasoning: `RelayTo(target, sub)` ends this round and starts a fresh
                    // one at the target with the command's sub-program (single-level relay). The
                    // abandoned cone resolves `Inactive` implicitly — the round simply stops here.
                    Some(target_idx) => {
                        // Fuel check: a relay chain longer than the bound is cut with a loud error
                        // (a relay cycle is the likely cause) instead of looping forever.
                        if relay_rounds_left == 0 {
                            let (_, state, context, logs) = last_effect.into_parts();
                            return PropagatingEffect::new(
                                Err(CausalityError(CausalityErrorEnum::Custom(format!(
                                    "Relay budget exhausted: the adaptive-reasoning chain exceeded \
                                     MAX_RELAY_ROUNDS = {MAX_RELAY_ROUNDS} rounds (a relay cycle is \
                                     likely). The relay handler is fuel-bounded so evaluation \
                                     terminates (core.causal_effect.relay_termination)."
                                )))),
                                state,
                                context,
                                logs,
                            );
                        }
                        relay_rounds_left -= 1;
                        if !self.contains_causaloid(target_idx) {
                            let (_, state, context, logs) = last_effect.into_parts();
                            return PropagatingEffect::new(
                                Err(CausalityError(CausalityErrorEnum::Custom(format!(
                                    "RelayTo target causaloid with index {target_idx} not found in graph."
                                )))),
                                state,
                                context,
                                logs,
                            );
                        }
                        let logs = last_effect.logs().clone();
                        let relayed_effect = result_effect
                            .into_parts()
                            .0
                            .ok()
                            .and_then(CausalEffect::into_command)
                            .map(|(_, sub)| sub)
                            .unwrap_or_else(CausalEffect::none);
                        round_start = target_idx;
                        round_input = PropagatingEffect::new(Ok(relayed_effect), (), None, logs);
                        continue 'rounds;
                    }
                    // A value/`None` result fires: publish it to each child's wire slot.
                    None => {
                        let children = match self.get_graph().outbound_edges(node) {
                            Ok(c) => c,
                            Err(e) => {
                                let (_, state, context, logs) = last_effect.into_parts();
                                return PropagatingEffect::new(
                                    Err(CausalityError(CausalityErrorEnum::Custom(format!("{e}")))),
                                    state,
                                    context,
                                    logs,
                                );
                            }
                        };
                        for c in children {
                            if reachable[c] && !processed[c] {
                                fired[c].insert(node, result_effect.clone());
                                pending[c] = pending[c].saturating_sub(1);
                                if pending[c] == 0 {
                                    ready.insert(c);
                                }
                            }
                        }
                    }
                }
            }

            // Round complete: return the effect of the last node processed.
            return last_effect;
        }
    }
    /// Reasons over the shortest path between a start and stop cause using a monadic approach.
    ///
    /// It evaluates each node sequentially along the path. The `PropagatingEffect` returned by
    /// one causaloid becomes the input for the next causaloid in the path. If any node
    /// fails evaluation (i.e., returns a `PropagatingEffect` containing an error) or returns
    /// a `RelayTo` effect, the reasoning stops.
    ///
    /// # Arguments
    ///
    /// * `start_index` - The index of the start cause.
    /// * `stop_index` - The index of the stop cause.
    /// * `initial_effect` - The runtime effect to be passed as input to the first node's evaluation function.
    ///
    /// # Returns
    ///
    /// A `PropagatingEffect` representing the final aggregated monadic effect of the path traversal.
    /// If an error occurs or a `RelayTo` effect is encountered, that `PropagatingEffect` is returned immediately.
    fn evaluate_shortest_path_between_causes(
        &self,
        start_index: usize,
        stop_index: usize,
        initial_effect: &PropagatingEffect<V>,
    ) -> PropagatingEffect<V> {
        if !self.is_frozen() {
            return PropagatingEffect::from_error(CausalityError(CausalityErrorEnum::Custom(
                "Graph is not frozen. Call freeze() first".into(),
            )));
        }

        // Handle the single-node case explicitly before calling the pathfinder.
        if start_index == stop_index {
            let causaloid = match self.get_causaloid(start_index) {
                Some(c) => c,
                None => {
                    return PropagatingEffect::from_error(CausalityError(
                        CausalityErrorEnum::Custom(format!(
                            "Failed to get causaloid at index {start_index}"
                        )),
                    ));
                }
            };
            return causaloid.evaluate(initial_effect);
        }

        let path = match self.get_shortest_path(start_index, stop_index) {
            Ok(p) => p,
            Err(e) => {
                return PropagatingEffect::from_error(CausalityError(CausalityErrorEnum::Custom(
                    format!("{:?}", e),
                )));
            }
        };

        let mut current_effect = initial_effect.clone();

        for index in path {
            let causaloid = match self.get_causaloid(index) {
                Some(c) => c,
                None => {
                    return PropagatingEffect::from_error(CausalityError(
                        CausalityErrorEnum::Custom(format!(
                            "Failed to get causaloid at index {index}"
                        )),
                    ));
                }
            };

            // Evaluate the current cause with the effect propagated from the previous node.
            current_effect = causaloid.evaluate(&current_effect);

            // If an error occurred, propagate it and stop.
            if current_effect.is_err() {
                return current_effect;
            }

            // If a RelayTo command is returned, stop the shortest path traversal and return it
            if current_effect.command_target().is_some() {
                return current_effect;
            }
        }

        // If the loop completes, all nodes on the path were successfully evaluated.
        current_effect
    }
}
