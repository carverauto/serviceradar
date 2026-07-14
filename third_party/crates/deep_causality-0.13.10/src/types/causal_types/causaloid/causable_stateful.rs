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
use deep_causality_core::{CausalityError, CausalityErrorEnum, EffectValue, PropagatingProcess};
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
        if let Some(err) = incoming.error.clone() {
            return PropagatingProcess {
                value: EffectValue::None,
                state: incoming.state.clone(),
                context: incoming.context.clone(),
                error: Some(err),
                logs: incoming.logs.clone(),
            };
        }

        match self.causal_type {
            CausaloidType::Singleton => {
                let id = self.id;

                // Step 1: log the input. Threads incoming state, context, and logs.
                let input_value: I = match incoming.value.clone() {
                    EffectValue::Value(v) => v,
                    EffectValue::None => {
                        return PropagatingProcess {
                            value: EffectValue::None,
                            state: incoming.state.clone(),
                            context: incoming.context.clone(),
                            error: Some(CausalityError(CausalityErrorEnum::Custom(
                                "Cannot evaluate: input value is None".into(),
                            ))),
                            logs: incoming.logs.clone(),
                        };
                    }
                    other => {
                        // RelayTo / ContextualLink / Map flow through unchanged.
                        return PropagatingProcess {
                            value: cast_effect_value(other),
                            state: incoming.state.clone(),
                            context: incoming.context.clone(),
                            error: None,
                            logs: incoming.logs.clone(),
                        };
                    }
                };

                let stage1 = causable_utils::log_input_stateful::<I, PS, C>(
                    input_value.clone(),
                    id,
                    incoming.state.clone(),
                    incoming.context.clone(),
                );
                // Carry forward logs from the incoming process.
                let mut combined_logs = incoming.logs.clone();
                {
                    use deep_causality_haft::LogAppend;
                    let mut s1_logs = stage1.logs.clone();
                    combined_logs.append(&mut s1_logs);
                }

                // Step 2: execute the causal logic statefully.
                let stage2 = causable_utils::execute_causal_logic_stateful::<I, O, PS, C>(
                    input_value,
                    stage1.state,
                    stage1.context,
                    self,
                );

                {
                    use deep_causality_haft::LogAppend;
                    let mut s2_logs = stage2.logs.clone();
                    combined_logs.append(&mut s2_logs);
                }

                if let Some(error) = stage2.error {
                    return PropagatingProcess {
                        value: EffectValue::None,
                        state: stage2.state,
                        context: stage2.context,
                        error: Some(error),
                        logs: combined_logs,
                    };
                }

                let output_value: O = match stage2.value {
                    EffectValue::Value(v) => v,
                    EffectValue::None => {
                        return PropagatingProcess {
                            value: EffectValue::None,
                            state: stage2.state,
                            context: stage2.context,
                            error: Some(CausalityError(CausalityErrorEnum::Custom(
                                "Causaloid::evaluate_stateful: causal_fn returned None output"
                                    .into(),
                            ))),
                            logs: combined_logs,
                        };
                    }
                    other => {
                        // Pass through structural variants (RelayTo etc.) without further logging.
                        return PropagatingProcess {
                            value: other,
                            state: stage2.state,
                            context: stage2.context,
                            error: None,
                            logs: combined_logs,
                        };
                    }
                };

                // Step 3: log the output.
                let stage3 = causable_utils::log_output_stateful::<O, PS, C>(
                    output_value,
                    id,
                    stage2.state,
                    stage2.context,
                );

                {
                    use deep_causality_haft::LogAppend;
                    let mut s3_logs = stage3.logs.clone();
                    combined_logs.append(&mut s3_logs);
                }

                PropagatingProcess {
                    value: stage3.value,
                    state: stage3.state,
                    context: stage3.context,
                    error: None,
                    logs: combined_logs,
                }
            }

            CausaloidType::Collection => PropagatingProcess {
                value: EffectValue::None,
                state: incoming.state.clone(),
                context: incoming.context.clone(),
                error: Some(CausalityError(CausalityErrorEnum::Custom(
                    "Stateful collection evaluation requires StatefulMonadicCausableCollection::evaluate_collection_stateful"
                        .into(),
                ))),
                logs: incoming.logs.clone(),
            },

            CausaloidType::Graph => PropagatingProcess {
                value: EffectValue::None,
                state: incoming.state.clone(),
                context: incoming.context.clone(),
                error: Some(CausalityError(CausalityErrorEnum::Custom(
                    "Stateful graph evaluation requires StatefulMonadicCausableGraphReasoning::evaluate_subgraph_from_cause_stateful"
                        .into(),
                ))),
                logs: incoming.logs.clone(),
            },
        }
    }
}

/// Pass through structural [`EffectValue`] variants from input to output type.
///
/// `RelayTo`, `ContextualLink`, and `Map` carry no payload of type `I` that
/// would need transformation to `O`; they are control-flow markers. Returning
/// `EffectValue::None` here is the conservative choice that surfaces a clear
/// signal at the next reasoning step (the caller can detect the change of
/// kind). For singleton evaluation these variants are not expected on the
/// input channel; the branch exists for completeness.
fn cast_effect_value<I, O>(_v: EffectValue<I>) -> EffectValue<O> {
    EffectValue::None
}
