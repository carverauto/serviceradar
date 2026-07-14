/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stateful counterpart to [`super::monadic_collection::MonadicCausableCollection`].
//!
//! Mirrors the aggregation pipeline of the stateless trait but threads the
//! caller-supplied `S` (state) and `C` (context) through every per-item
//! evaluation, returning a `PropagatingProcess<O, S, C>`. Aggregation logic
//! itself is delegated to the existing
//! [`crate::utils::monadic_collection_utils::aggregate_effects`] helper, which
//! is state-agnostic.
//!
//! Statefulness is selected by calling this trait method instead of the
//! stateless one. No new collection constructor is required.

use crate::{
    AggregateLogic, Causable, CausableCollectionAccessor, CausalityError, CausalityErrorEnum,
    MonadicCausable, NumericalValue, StatefulMonadicCausable, monadic_collection_utils,
};
use deep_causality_core::{EffectValue, PropagatingProcess};
use deep_causality_haft::LogAppend;
use std::fmt::Debug;

/// Stateful counterpart to [`crate::MonadicCausableCollection`].
///
/// Each child item's `evaluate_stateful` is invoked with a process whose
/// `state` and `context` reflect the accumulator state propagated by the
/// preceding items; the resulting `state` and `context` are threaded forward
/// into the next item. After all items have been evaluated, their per-item
/// values are aggregated via `AggregateLogic` exactly as in the stateless
/// path.
///
/// Use the existing [`crate::Causaloid::from_causal_collection_with_context`]
/// to author a collection causaloid; no "stateful" sibling constructor exists
/// or is needed (statefulness is a property of the call, not the
/// constructor).
pub trait StatefulMonadicCausableCollection<I, O, S, C, T>:
    CausableCollectionAccessor<I, O, T>
where
    T: MonadicCausable<I, O> + StatefulMonadicCausable<I, O, S, C> + Causable,
    I: Clone,
    O: monadic_collection_utils::Aggregatable + Clone + Default + Send + Sync + 'static + Debug,
    S: Clone + Default,
    C: Clone,
{
    /// Stateful collection evaluation.
    ///
    /// # Arguments
    /// * `incoming` - The `PropagatingProcess<I, S, C>` passed to each item.
    /// * `logic` - The `AggregateLogic` used to combine per-item values.
    /// * `threshold_value` - Optional numeric threshold used by some logics.
    ///
    /// # Returns
    /// A `PropagatingProcess<O, S, C>` whose `state` and `context` reflect the
    /// last successful per-item state mutation, and whose `logs` aggregate
    /// every step in chronological order.
    ///
    /// # Errors
    /// Returns a `PropagatingProcess` carrying an error if the collection is
    /// empty, if any item returns an error (short-circuiting subsequent
    /// items), or if aggregation fails. On error, `state` and `context`
    /// reflect the last successful per-item mutation (i.e. the state the
    /// failing item received as input).
    fn evaluate_collection_stateful(
        &self,
        incoming: &PropagatingProcess<I, S, C>,
        logic: &AggregateLogic,
        threshold_value: Option<NumericalValue>,
    ) -> PropagatingProcess<O, S, C> {
        // Short-circuit if the incoming process already carries an error.
        if let Some(err) = incoming.error.clone() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: incoming.state.clone(),
                context: incoming.context.clone(),
                error: Some(err),
                logs: incoming.logs.clone(),
            };
        }

        let items = self.get_all_items();

        if items.is_empty() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: incoming.state.clone(),
                context: incoming.context.clone(),
                error: Some(CausalityError(CausalityErrorEnum::Custom(
                    "Cannot evaluate an empty collection".to_string(),
                ))),
                logs: incoming.logs.clone(),
            };
        }

        // Accumulator: process carrying (Vec<EffectValue<O>>, threaded S, C, logs).
        let mut acc_values: Vec<EffectValue<O>> = Vec::with_capacity(items.len());
        let mut acc_state: S = incoming.state.clone();
        let mut acc_context: Option<C> = incoming.context.clone();
        let mut acc_logs = incoming.logs.clone();

        for item in items.into_iter() {
            // Build a per-item incoming process that carries the threaded state.
            let item_in: PropagatingProcess<I, S, C> = PropagatingProcess {
                value: incoming.value.clone(),
                state: acc_state.clone(),
                context: acc_context.clone(),
                error: None,
                logs: Default::default(),
            };

            let mut item_out = item.evaluate_stateful(&item_in);

            // Always merge the item's logs into the accumulator first.
            acc_logs.append(&mut item_out.logs);

            if let Some(err) = item_out.error.take() {
                return PropagatingProcess {
                    value: EffectValue::None,
                    // State at moment of failure: the state the failing item
                    // received as input (i.e. the accumulator before this item).
                    state: acc_state,
                    context: acc_context,
                    error: Some(err),
                    logs: acc_logs,
                };
            }

            // Advance the accumulator state and context to the item's outputs.
            acc_state = item_out.state;
            acc_context = item_out.context;
            acc_values.push(item_out.value);
        }

        // Aggregate the per-item values.
        match monadic_collection_utils::aggregate_effects(&acc_values, logic, threshold_value) {
            Ok(aggregated_value) => PropagatingProcess {
                value: aggregated_value,
                state: acc_state,
                context: acc_context,
                error: None,
                logs: acc_logs,
            },
            Err(e) => PropagatingProcess {
                value: EffectValue::None,
                state: acc_state,
                context: acc_context,
                error: Some(e),
                logs: acc_logs,
            },
        }
    }
}
