/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the core behavior of `Causaloid` instances within the DeepCausality framework,
//! specifically how they implement the `Causable` and `MonadicCausable` traits.
//!
//! It details the evaluation logic for different types of `Causaloid`s (Singleton, Collection, Graph),
//! ensuring proper error propagation and comprehensive log provenance through monadic operations.

use crate::types::causal_types::causaloid::causable_utils;
use crate::{
    Causable, CausalityError, Causaloid, CausaloidType, MonadicCausable, PropagatingEffect,
};
use std::fmt::Debug;

/// The seal: `Causaloid` is the ONLY carrier of the causal trait surface — the three
/// `CausaloidType` forms are closed (`algebraic-causaloid-assumptions.md` #11a, DECIDED).
impl<I, O, PS, C> crate::traits::causable::sealed::Sealed for Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
}

/// Implements the `Causable` trait for `Causaloid`.
///
/// This trait provides fundamental properties and methods for any entity that can
/// participate in a causal relationship. For `Causaloid`, it primarily defines
/// how to determine if a causaloid represents a single, atomic causal unit.
impl<I, O, PS, C> Causable for Causaloid<I, O, PS, C>
where
    I: Default,
    O: Default + Debug,
    PS: Default + Clone,
    C: Clone,
{
    /// Checks if the `Causaloid` is of type `Singleton`.
    ///
    /// A singleton causaloid represents an atomic causal relationship that
    /// can be evaluated independently.
    ///
    /// # Returns
    /// `true` if the `CausaloidType` is `Singleton`, `false` otherwise.
    fn is_singleton(&self) -> bool {
        matches!(self.causal_type, CausaloidType::Singleton)
    }
}

/// Implements the `MonadicCausable` trait for `Causaloid`.
///
/// This implementation provides the core evaluation logic for `Causaloid`s,
/// leveraging monadic principles to handle the flow of effects, errors, and logs.
///
/// **Note**: This base implementation only supports `CausaloidType::Singleton`.
/// For `Collection` and `Graph` evaluation with aggregation support, use the
/// specialized constructors that ensure proper trait bounds are met.
#[allow(clippy::type_complexity)]
impl<I, O, PS, C> MonadicCausable<I, O> for Causaloid<I, O, PS, C>
where
    I: Default + Clone + Send + Sync + 'static + Debug,
    O: Default + Debug + Clone + Send + Sync + 'static,
    PS: Default + Clone + Send + Sync + 'static,
    C: Clone + Send + Sync + 'static,
{
    /// Evaluates the causal effect of this `Causaloid` given an `incoming_effect`.
    ///
    /// The evaluation process is monadic, ensuring that errors are propagated
    /// and a comprehensive log of operations is maintained.
    ///
    /// **Important**: This base implementation only supports `Singleton` causaloids.
    /// For `Collection` and `Graph` types, specialized evaluation methods with
    /// proper trait bounds should be used.
    ///
    /// # Arguments
    /// * `incoming_effect` - The `PropagatingEffect` representing the input to this causaloid.
    ///
    /// # Returns
    /// A `PropagatingEffect` containing the result of the causal evaluation,
    /// any errors encountered, and a complete log of the operations performed.
    fn evaluate(&self, incoming_effect: &PropagatingEffect<I>) -> PropagatingEffect<O> {
        match self.causal_type {
            CausaloidType::Singleton => {
                // A command input (`RelayTo`) cannot be consumed by a singleton: it carries no `I`
                // value to evaluate and cannot be retyped `I -> O`. The reasoning engine relays a
                // command's sub-program, so a singleton never receives a live command on its input
                // channel in normal operation. Surface a clear, command-specific error rather than
                // letting the `bind_or_error` step below report it as a generic "input value is None"
                // — which would conflate a dropped command with absence of evidence. This mirrors the
                // stateful `StatefulMonadicCausable::evaluate_stateful` path exactly.
                if incoming_effect.command_target().is_some() {
                    return PropagatingEffect::new(
                        Err(CausalityError(
                            deep_causality_core::CausalityErrorEnum::Custom(
                                "Causaloid::evaluate: singleton received a command (RelayTo) on its \
                                 input channel; commands are relayed by the reasoning engine, not \
                                 consumed by a singleton"
                                    .into(),
                            ),
                        )),
                        (),
                        None,
                        incoming_effect.logs().clone(),
                    );
                }

                // For a Singleton, the evaluation is a monadic chain of operations:
                // 1. Log the input.
                // 2. Execute the causal logic.
                // 3. Log the output.
                // The `bind` operations ensure that logs are aggregated and errors short-circuit.
                incoming_effect
                    .clone()
                    .bind_or_error(
                        |input, _, _| causable_utils::log_input(input, self.id),
                        "Cannot evaluate: input value is None",
                    )
                    .bind_or_error(
                        |input, _, _| causable_utils::execute_causal_logic(input, self),
                        "Cannot evaluate: input value after logging is None",
                    )
                    .bind(|output_effect_val, _, _| {
                        // A command output passes through unchanged for the reasoning engine to fold.
                        if output_effect_val.is_command() {
                            return PropagatingEffect::from_effect(output_effect_val);
                        }
                        match output_effect_val.into_value() {
                            Some(v) => causable_utils::log_output(v, self.id),
                            None => PropagatingEffect::from_error(CausalityError(
                                deep_causality_core::CausalityErrorEnum::Custom(
                                    "Causaloid::evaluate: causal_fn returned None output".into(),
                                ),
                            )),
                        }
                    })
            }

            CausaloidType::Collection => {
                // Preserve incoming logs and include a precise error message.
                PropagatingEffect::new(
                    Err(CausalityError(
                        deep_causality_core::CausalityErrorEnum::Custom(
                            "Collection evaluation is not available in this build; \
                             use specialized collection evaluation APIs."
                                .into(),
                        ),
                    )),
                    (),
                    None,
                    incoming_effect.logs().clone(),
                )
            }
            CausaloidType::Graph => {
                // Preserve incoming logs and include a precise error message.
                PropagatingEffect::new(
                    Err(CausalityError(
                        deep_causality_core::CausalityErrorEnum::Custom(
                            "Graph evaluation is not available in this build; \
                             use specialized graph evaluation APIs."
                                .into(),
                        ),
                    )),
                    (),
                    None,
                    incoming_effect.logs().clone(),
                )
            }
        }
    }
}
