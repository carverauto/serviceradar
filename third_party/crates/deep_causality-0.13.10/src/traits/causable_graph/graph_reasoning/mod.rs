/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod stateful;

use crate::*;
use deep_causality_haft::LogAppend;
use std::collections::VecDeque;
use std::fmt::Debug;
use ultragraph::GraphTraversal;

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
    V: Default + Clone + Send + Sync + 'static + Debug,
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

    /// Reasons over a subgraph by traversing all nodes reachable from a given start index,
    /// using a monadic approach.
    ///
    /// This method performs a Breadth-First Search (BFS) traversal of all descendants
    /// of the `start_index`. The `PropagatingEffect` is passed sequentially:
    /// the output effect of a parent node becomes the input effect for its child node.
    /// The traversal continues as long as no `CausalityError` is returned within the `PropagatingEffect`.
    ///
    /// ## Adaptive Reasoning
    ///
    /// If a `Causaloid` returns a `PropagatingEffect::RelayTo(target_index, inner_effect)`,
    /// the BFS traversal dynamically jumps to  `target_index`, and `inner_effect` becomes
    /// the new input for the relayed path. This enables *adaptive reasoning* conditional to the deciding
    /// causaloid.
    ///
    /// # Arguments
    ///
    /// * `start_index` - The index of the node to start the traversal from.
    /// * `initial_effect` - The initial runtime effect to be passed to the starting node's evaluation function.
    ///
    /// # Returns
    ///
    /// A `PropagatingEffect` representing the final aggregated monadic effect of the traversal.
    /// If an error occurs during evaluation, the returned `PropagatingEffect` will contain the error.
    fn evaluate_subgraph_from_cause(
        &self,
        start_index: usize,
        initial_effect: &PropagatingEffect<V>,
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

        // Queue stores (node_index, incoming_effect_for_this_node)
        let mut queue =
            VecDeque::<(usize, PropagatingEffect<V>)>::with_capacity(self.number_nodes());
        let mut visited = vec![false; self.number_nodes()];

        // Initialize the queue with the starting node and the initial effect
        queue.push_back((start_index, initial_effect.clone()));
        visited[start_index] = true;

        // This will hold the effect of the last successfully processed node.
        let mut last_propagated_effect = initial_effect.clone();

        while let Some((current_index, incoming_effect)) = queue.pop_front() {
            let causaloid = match self.get_causaloid(current_index) {
                Some(c) => c,
                None => {
                    return PropagatingEffect::from_error(CausalityError(
                        CausalityErrorEnum::Custom(format!(
                            "Failed to get causaloid at index {current_index}"
                        )),
                    ));
                }
            };

            // Evaluate the current cause using the incoming_effect.
            let result_effect = causaloid.evaluate(&incoming_effect);

            // Update the last_propagated_effect with the result of the current node's evaluation.
            last_propagated_effect = result_effect.clone();

            // If an error occurred, propagate it and stop further processing for this path.
            if result_effect.is_err() {
                return result_effect;
            }

            match &result_effect.value {
                // Adaptive reasoning:
                EffectValue::RelayTo(target_index, inner_effect) => {
                    // Reset traversal state to follow the relayed path exclusively.
                    visited.fill(false);
                    queue.clear();

                    let target_idx = *target_index;

                    if !self.contains_causaloid(target_idx) {
                        let mut err_effect = last_propagated_effect.clone();

                        err_effect.error = Some(CausalityError(CausalityErrorEnum::Custom(
                            format!(
                                "RelayTo target causaloid with index {target_idx} not found in graph."
                            ),
                        )));
                        return err_effect;
                    }

                    visited[target_idx] = true;

                    let mut relayed = *inner_effect.clone();
                    relayed.logs.append(&mut last_propagated_effect.logs);
                    queue.push_back((target_idx, relayed));
                }
                _ => {
                    let children = match self.get_graph().outbound_edges(current_index) {
                        Ok(c) => c,
                        Err(e) => {
                            let mut err_effect = last_propagated_effect.clone();
                            err_effect.error =
                                Some(CausalityError(CausalityErrorEnum::Custom(format!("{e}"))));
                            return err_effect;
                        }
                    };
                    for child_index in children {
                        if !visited[child_index] {
                            visited[child_index] = true;
                            // Pass the result_effect of the current node to its children.
                            queue.push_back((child_index, result_effect.clone()));
                        }
                    }
                }
            }
        }

        // If the loop completes, return the effect of the last node processed.
        last_propagated_effect
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

            // If a RelayTo effect is returned, stop the shortest path traversal and return it
            if let EffectValue::RelayTo(_, _) = current_effect.value {
                return current_effect;
            }
        }

        // If the loop completes, all nodes on the path were successfully evaluated.
        current_effect
    }
}
