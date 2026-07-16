/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stateful evaluation impl for [`Causaloid`].
//!
//! Mirrors the structure of [`super::causable`] but threads `STATE` and
//! `CTX` through the evaluation result rather than collapsing them at the
//! trait-method boundary. The base implementation supports
//! `CausaloidType::Singleton` directly; `Collection` and `Graph` causal types
//! return a precise error directing the caller to the specialised stateful
//! collection / graph reasoning APIs (mirroring the existing stateless
//! behaviour).

use crate::types::causal_types::causaloid::causable_utils;
use crate::{Causaloid, CausaloidType, StatefulMonadicCausable};
use deep_causality_core::{CausalityError, CausalityErrorEnum, PropagatingProcess};
use std::fmt::Debug;

impl<I, O, PS, C> StatefulMonadicCausable<I, O, PS, C> for Causaloid<I, O, PS, C>
where
    I: Default + Clone + Send + Sync + 'static + Debug,
    O: Default + Debug + Clone + Send + Sync + 'static,
    PS: Default + Clone + Send + Sync + 'static + Debug,
    C: Clone + Send + Sync + 'static,
{
    fn evaluate_stateful(
        &self,
        incoming: &PropagatingProcess<I, PS, C>,
    ) -> PropagatingProcess<O, PS, C> {
        // Short-circuit if the incoming process already carries an error.
        // Mirrors the bind-semantics on `CausalEffectPropagationProcess`:
        // an error process passes through downstream stages unchanged,
        // preserving state, context, and logs accumulated up to the failure.
        // (Value and error are one channel, so an errored process provably
        // carries no value for the stages below to consume.)
        let incoming_value = match incoming.outcome() {
            Err(err) => {
                return PropagatingProcess::new(
                    Err(err.clone()),
                    incoming.state().clone(),
                    incoming.context().clone(),
                    incoming.logs().clone(),
                );
            }
            Ok(value) => value.clone(),
        };

        match self.causal_type {
            CausaloidType::Singleton => {
                let id = self.id;

                // Step 1: log the input. Threads incoming state, context, and logs.
                // A command input (`RelayTo`) cannot be consumed by a singleton: it carries no `I`
                // value to evaluate, and it cannot be retyped `I -> O` (its sub-program has
                // `Option<I>` leaves and no `I -> O` map exists before evaluation). The reasoning
                // engine relays a command's sub-value, so a singleton never receives a live command
                // on its input channel in normal operation; surfacing it as a clear error preserves
                // the signal (target + sub-effect) instead of silently manufacturing `None` — which
                // would read downstream as absence of evidence rather than a dropped command. This
                // mirrors the stateless `Causable::evaluate` path, where a command input errors.
                if incoming_value.is_command() {
                    return PropagatingProcess::new(
                        Err(CausalityError(CausalityErrorEnum::Custom(
                            "Causaloid::evaluate_stateful: singleton received a command (RelayTo) \
                             on its input channel; commands are relayed by the reasoning engine, \
                             not consumed by a singleton"
                                .into(),
                        ))),
                        incoming.state().clone(),
                        incoming.context().clone(),
                        incoming.logs().clone(),
                    );
                }
                let input_value: I = match incoming_value.into_value() {
                    Some(v) => v,
                    None => {
                        return PropagatingProcess::new(
                            Err(CausalityError(CausalityErrorEnum::Custom(
                                "Cannot evaluate: input value is None".into(),
                            ))),
                            incoming.state().clone(),
                            incoming.context().clone(),
                            incoming.logs().clone(),
                        );
                    }
                };

                let stage1 = causable_utils::log_input_stateful::<I, PS, C>(
                    input_value.clone(),
                    id,
                    incoming.state().clone(),
                    incoming.context().clone(),
                );
                let (_stage1_outcome, stage1_state, stage1_context, stage1_logs) =
                    stage1.into_parts();

                // Carry forward logs from the incoming process.
                let mut combined_logs = incoming.logs().clone();
                {
                    use deep_causality_haft::LogAppend;
                    let mut s1_logs = stage1_logs;
                    combined_logs.append(&mut s1_logs);
                }

                // Step 2: execute the causal logic statefully.
                let stage2 = causable_utils::execute_causal_logic_stateful::<I, O, PS, C>(
                    input_value,
                    stage1_state,
                    stage1_context,
                    self,
                );
                let (stage2_outcome, stage2_state, stage2_context, stage2_logs) =
                    stage2.into_parts();

                {
                    use deep_causality_haft::LogAppend;
                    let mut s2_logs = stage2_logs;
                    combined_logs.append(&mut s2_logs);
                }

                let output_value: O = match stage2_outcome {
                    Err(error) => {
                        return PropagatingProcess::new(
                            Err(error),
                            stage2_state,
                            stage2_context,
                            combined_logs,
                        );
                    }
                    // A command output passes through unchanged (same `O`) without further logging.
                    Ok(effect) if effect.is_command() => {
                        return PropagatingProcess::new(
                            Ok(effect),
                            stage2_state,
                            stage2_context,
                            combined_logs,
                        );
                    }
                    Ok(effect) => match effect.into_value() {
                        Some(v) => v,
                        None => {
                            return PropagatingProcess::new(
                                Err(CausalityError(CausalityErrorEnum::Custom(
                                    "Causaloid::evaluate_stateful: causal_fn returned None output"
                                        .into(),
                                ))),
                                stage2_state,
                                stage2_context,
                                combined_logs,
                            );
                        }
                    },
                };

                // Step 3: log the output.
                let stage3 = causable_utils::log_output_stateful::<O, PS, C>(
                    output_value,
                    id,
                    stage2_state,
                    stage2_context,
                );
                let (stage3_outcome, stage3_state, stage3_context, stage3_logs) =
                    stage3.into_parts();

                {
                    use deep_causality_haft::LogAppend;
                    let mut s3_logs = stage3_logs;
                    combined_logs.append(&mut s3_logs);
                }

                PropagatingProcess::new(stage3_outcome, stage3_state, stage3_context, combined_logs)
            }

            CausaloidType::Collection => PropagatingProcess::new(
                Err(CausalityError(CausalityErrorEnum::Custom(
                    "Stateful collection evaluation requires StatefulMonadicCausableCollection::evaluate_collection_stateful"
                        .into(),
                ))),
                incoming.state().clone(),
                incoming.context().clone(),
                incoming.logs().clone(),
            ),

            CausaloidType::Graph => PropagatingProcess::new(
                Err(CausalityError(CausalityErrorEnum::Custom(
                    "Stateful graph evaluation requires StatefulMonadicCausableGraphReasoning::evaluate_subgraph_from_cause_stateful"
                        .into(),
                ))),
                incoming.state().clone(),
                incoming.context().clone(),
                incoming.logs().clone(),
            ),
        }
    }
}
