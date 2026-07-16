/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{
    AggregateLogic, Causable, CausableCollectionAccessor, CausalityError, MonadicCausable,
    NumericalValue, PropagatingEffect, monadic_collection_utils,
};
use deep_causality_core::{CausalEffect, CausalityErrorEnum};

pub trait MonadicCausableCollection<I, O, T>: CausableCollectionAccessor<I, O, T>
where
    T: MonadicCausable<I, O> + Causable,
    O: monadic_collection_utils::Aggregatable
        + Clone
        + Default
        + Send
        + Sync
        + 'static
        + std::fmt::Debug,
{
    /// Evaluates a collection of `MonadicCausable` items, aggregating their monadic effects.
    ///
    /// This method provides a single, unified entry point for reasoning over a collection of causable items.
    /// It monadically evaluates each item and then uses a type-aware aggregation strategy to combine
    /// the results.
    ///
    /// # Arguments
    ///
    /// * `incoming_effect` - A `PropagatingEffect` to be passed to each `MonadicCausable` item.
    /// * `logic` - The `AggregateLogic` (e.g., `All`, `Any`, `None`, `Some(k)`) that defines how the results are combined.
    /// * `threshold_value` - An optional `NumericalValue` used for comparisons (e.g., converting a probability to a boolean).
    ///   It is required for some aggregation strategies.
    ///
    /// # Returns
    ///
    /// A `PropagatingEffect` representing the aggregated monadic effect of the collection.
    ///
    /// # Errors
    ///
    /// Returns a `PropagatingEffect` containing a `CausalityError` if:
    /// * The collection is empty.
    /// * An item's `evaluate` method returns an error.
    fn evaluate_collection(
        &self,
        incoming_effect: &PropagatingEffect<I>,
        logic: &AggregateLogic,
        threshold_value: Option<NumericalValue>,
    ) -> PropagatingEffect<O> {
        let items = self.get_all_items();

        if items.is_empty() {
            let err = CausalityError(CausalityErrorEnum::Custom(
                "Cannot evaluate an empty collection".to_string(),
            ));
            return PropagatingEffect::from_error(err);
        }
        // 1. Monadic fold to collect all effects.
        // We start with a pure effect containing an empty vector of CausalEffect<O>.
        let initial_effect: PropagatingEffect<Vec<CausalEffect<O>>> =
            PropagatingEffect::pure(Vec::new());

        let final_effect = items.into_iter().fold(initial_effect, |acc_effect, item| {
            acc_effect.bind(|acc_values_effect_value, acc_state, acc_ctx| {
                let mut acc_values = match acc_values_effect_value.into_value() {
                    Some(v) => v,
                    None => {
                        let err = CausalityError(CausalityErrorEnum::Custom(
                            "Failed to extract accumulated values during collection evaluation"
                                .to_string(),
                        ));
                        return PropagatingEffect::from_error(err);
                    }
                };
                let item_effect = item.evaluate(incoming_effect); // PropagatingEffect<O>
                let (item_outcome, _unit_state, _no_context, item_logs) = item_effect.into_parts();

                match item_outcome {
                    // If the item effect is an error, carry its logs forward (the accumulator
                    // logs are already merged by the outer `bind`).
                    Err(err) => PropagatingEffect::new(Err(err), acc_state, acc_ctx, item_logs),
                    Ok(item_value) => {
                        acc_values.push(item_value);
                        // Carry the item's logs forward alongside the grown accumulator.
                        PropagatingEffect::new(
                            Ok(CausalEffect::value(acc_values)),
                            (),
                            None,
                            item_logs,
                        )
                    }
                }
            })
        });

        // 2. Bind the final aggregation logic.
        // Note: `bind` passes logs from `final_effect` to the returned effect automatically
        // via log aggregation in `bind` implementation. We capture carried_logs explicitly
        // to ensure they are preserved even when we create new effects.
        let carried_logs = final_effect.logs().clone();

        final_effect.bind(move |effect_values_effect_value, _, _| {
            // effect_values_effect_value is CausalEffect<Vec<CausalEffect<O>>>
            // We need to extract the Vec from it
            let effect_values = match effect_values_effect_value.into_value() {
                Some(v) => v,
                None => {
                    let err = CausalityError(CausalityErrorEnum::Custom(
                        "No effect values collected".to_string(),
                    ));
                    return PropagatingEffect::new(Err(err), (), None, carried_logs);
                }
            };
            // 3. Delegate to the robust aggregation helper.
            match monadic_collection_utils::aggregate_effects(
                &effect_values,
                logic,
                threshold_value,
            ) {
                // Preserve previously accumulated logs on both arms.
                Ok(aggregated_value) => {
                    PropagatingEffect::new(Ok(aggregated_value), (), None, carried_logs)
                }
                Err(e) => PropagatingEffect::new(Err(e), (), None, carried_logs),
            }
        })
    }
}
