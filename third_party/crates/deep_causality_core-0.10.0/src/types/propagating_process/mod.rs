/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
pub mod hkt;

use crate::EffectLog;
use crate::errors::causality_error::CausalityError;
use crate::types::causal_effect_propagation_process::CausalEffectPropagationProcess;

/// A stateful causal process with context.
///
/// `PropagatingProcess` is the full-featured alias for `CausalEffectPropagationProcess`.
///
/// *   **T**: The type of value being propagated.
/// *   **S**: The custom state type (e.g., a struct tracking accumulators or history).
/// *   **C**: The custom context type (e.g., config, read-only references).
///
/// Use this when your causal model needs to remember information between steps (Markdown property)
/// or access global configuration (Context).
pub type PropagatingProcess<T, S, C> =
    CausalEffectPropagationProcess<T, S, C, CausalityError, EffectLog>;
