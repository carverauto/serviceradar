/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stateful counterpart to [`super::MonadicCausableGraphReasoning`].
//!
//! Mirrors the BFS / shortest-path traversal of the stateless trait but
//! invokes [`crate::StatefulMonadicCausable::evaluate_stateful`] on each node,
//! threading the per-node `state` and `context` into the next node's incoming
//! process. The `RelayTo` adaptive-jump branch is preserved: when a node
//! returns `EffectValue::RelayTo(target, inner)` the relayed-to node receives
//! a `PropagatingProcess` whose `state` and `context` are the ones the
//! relaying node carried at the moment of relay.
//!
//! Statefulness is selected by calling these methods instead of the stateless
//! ones. No new graph constructor is required — use the existing
//! [`crate::Causaloid::from_causal_graph_with_context`].

use crate::*;
use deep_causality_haft::LogAppend;
use std::collections::VecDeque;
use std::fmt::Debug;
use ultragraph::GraphTraversal;

/// Stateful counterpart to [`crate::MonadicCausableGraphReasoning`].
pub trait StatefulMonadicCausableGraphReasoning<V, S, C>:
    CausableGraph<Causaloid<V, V, S, C>>
where
    V: Default + Clone + Send + Sync + 'static + Debug,
    S: Default + Clone + Send + Sync + 'static + Debug,
    C: Clone + Send + Sync + 'static,
    Causaloid<V, V, S, C>: MonadicCausable<V, V> + StatefulMonadicCausable<V, V, S, C>,
{
    /// Stateful counterpart to
    /// [`crate::MonadicCausableGraphReasoning::evaluate_single_cause`].
    fn evaluate_single_cause_stateful(
        &self,
        index: usize,
        effect: &PropagatingProcess<V, S, C>,
    ) -> PropagatingProcess<V, S, C> {
        // Short-circuit if the incoming process already carries an error.
        if let Some(err) = effect.error.clone() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: effect.state.clone(),
                context: effect.context.clone(),
                error: Some(err),
                logs: effect.logs.clone(),
            };
        }

        if !self.is_frozen() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: effect.state.clone(),
                context: effect.context.clone(),
                error: Some(CausalityError(CausalityErrorEnum::Custom(
                    "Graph is not frozen. Call freeze() first".into(),
                ))),
                logs: effect.logs.clone(),
            };
        }

        let causaloid = match self.get_causaloid(index) {
            Some(c) => c,
            None => {
                return PropagatingProcess {
                    value: EffectValue::None,
                    state: effect.state.clone(),
                    context: effect.context.clone(),
                    error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                        "Causaloid with index {index} not found in graph"
                    )))),
                    logs: effect.logs.clone(),
                };
            }
        };

        causaloid.evaluate_stateful(effect)
    }

    /// Stateful counterpart to
    /// [`crate::MonadicCausableGraphReasoning::evaluate_subgraph_from_cause`].
    fn evaluate_subgraph_from_cause_stateful(
        &self,
        start_index: usize,
        initial_effect: &PropagatingProcess<V, S, C>,
    ) -> PropagatingProcess<V, S, C> {
        // Short-circuit if the incoming process already carries an error.
        if let Some(err) = initial_effect.error.clone() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: initial_effect.state.clone(),
                context: initial_effect.context.clone(),
                error: Some(err),
                logs: initial_effect.logs.clone(),
            };
        }

        if !self.is_frozen() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: initial_effect.state.clone(),
                context: initial_effect.context.clone(),
                error: Some(CausalityError(CausalityErrorEnum::Custom(
                    "Graph is not frozen. Call freeze() first".into(),
                ))),
                logs: initial_effect.logs.clone(),
            };
        }

        if !self.contains_causaloid(start_index) {
            return PropagatingProcess {
                value: EffectValue::None,
                state: initial_effect.state.clone(),
                context: initial_effect.context.clone(),
                error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                    "Graph does not contain start causaloid with index {start_index}"
                )))),
                logs: initial_effect.logs.clone(),
            };
        }

        let mut queue =
            VecDeque::<(usize, PropagatingProcess<V, S, C>)>::with_capacity(self.number_nodes());
        let mut visited = vec![false; self.number_nodes()];

        queue.push_back((start_index, initial_effect.clone()));
        visited[start_index] = true;

        let mut last_propagated = initial_effect.clone();

        while let Some((current_index, incoming)) = queue.pop_front() {
            let causaloid = match self.get_causaloid(current_index) {
                Some(c) => c,
                None => {
                    return PropagatingProcess {
                        value: EffectValue::None,
                        state: last_propagated.state,
                        context: last_propagated.context,
                        error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                            "Failed to get causaloid at index {current_index}"
                        )))),
                        logs: last_propagated.logs,
                    };
                }
            };

            let result = causaloid.evaluate_stateful(&incoming);
            last_propagated = result.clone();

            if result.error.is_some() {
                return result;
            }

            match &result.value {
                EffectValue::RelayTo(target_index, inner_effect) => {
                    visited.fill(false);
                    queue.clear();

                    let target_idx = *target_index;

                    if !self.contains_causaloid(target_idx) {
                        return PropagatingProcess {
                            value: last_propagated.value,
                            state: last_propagated.state,
                            context: last_propagated.context,
                            error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                                "RelayTo target causaloid with index {target_idx} not found in graph."
                            )))),
                            logs: last_propagated.logs,
                        };
                    }

                    visited[target_idx] = true;

                    // Lift the stateless inner effect into a stateful process,
                    // preserving the state and context the relaying node carried.
                    let inner = (**inner_effect).clone();
                    let mut relayed: PropagatingProcess<V, S, C> = PropagatingProcess {
                        value: inner.value,
                        state: last_propagated.state.clone(),
                        context: last_propagated.context.clone(),
                        error: inner.error,
                        logs: inner.logs,
                    };
                    relayed.logs.append(&mut last_propagated.logs.clone());
                    queue.push_back((target_idx, relayed));
                }
                _ => {
                    let children = match self.get_graph().outbound_edges(current_index) {
                        Ok(c) => c,
                        Err(e) => {
                            return PropagatingProcess {
                                value: last_propagated.value,
                                state: last_propagated.state,
                                context: last_propagated.context,
                                error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                                    "{e}"
                                )))),
                                logs: last_propagated.logs,
                            };
                        }
                    };
                    for child_index in children {
                        if !visited[child_index] {
                            visited[child_index] = true;
                            queue.push_back((child_index, result.clone()));
                        }
                    }
                }
            }
        }

        last_propagated
    }

    /// Stateful counterpart to
    /// [`crate::MonadicCausableGraphReasoning::evaluate_shortest_path_between_causes`].
    fn evaluate_shortest_path_between_causes_stateful(
        &self,
        start_index: usize,
        stop_index: usize,
        initial_effect: &PropagatingProcess<V, S, C>,
    ) -> PropagatingProcess<V, S, C> {
        // Short-circuit if the incoming process already carries an error.
        if let Some(err) = initial_effect.error.clone() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: initial_effect.state.clone(),
                context: initial_effect.context.clone(),
                error: Some(err),
                logs: initial_effect.logs.clone(),
            };
        }

        if !self.is_frozen() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: initial_effect.state.clone(),
                context: initial_effect.context.clone(),
                error: Some(CausalityError(CausalityErrorEnum::Custom(
                    "Graph is not frozen. Call freeze() first".into(),
                ))),
                logs: initial_effect.logs.clone(),
            };
        }

        if start_index == stop_index {
            let causaloid = match self.get_causaloid(start_index) {
                Some(c) => c,
                None => {
                    return PropagatingProcess {
                        value: EffectValue::None,
                        state: initial_effect.state.clone(),
                        context: initial_effect.context.clone(),
                        error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                            "Failed to get causaloid at index {start_index}"
                        )))),
                        logs: initial_effect.logs.clone(),
                    };
                }
            };
            return causaloid.evaluate_stateful(initial_effect);
        }

        let path = match self.get_shortest_path(start_index, stop_index) {
            Ok(p) => p,
            Err(e) => {
                return PropagatingProcess {
                    value: EffectValue::None,
                    state: initial_effect.state.clone(),
                    context: initial_effect.context.clone(),
                    error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                        "{:?}",
                        e
                    )))),
                    logs: initial_effect.logs.clone(),
                };
            }
        };

        let mut current = initial_effect.clone();

        for index in path {
            let causaloid = match self.get_causaloid(index) {
                Some(c) => c,
                None => {
                    return PropagatingProcess {
                        value: EffectValue::None,
                        state: current.state,
                        context: current.context,
                        error: Some(CausalityError(CausalityErrorEnum::Custom(format!(
                            "Failed to get causaloid at index {index}"
                        )))),
                        logs: current.logs,
                    };
                }
            };

            current = causaloid.evaluate_stateful(&current);

            if current.error.is_some() {
                return current;
            }

            if let EffectValue::RelayTo(_, _) = current.value {
                return current;
            }
        }

        current
    }
}
