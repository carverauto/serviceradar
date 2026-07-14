/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalEffectPropagationProcess, CausalityError, EffectLog};

pub mod hkt;

/// A stateless causal effect.
///
/// `PropagatingEffect` is a simplified alias for `CausalEffectPropagationProcess` that has no state (`()`)
/// and no context (`()`). It is ideal for pure functional transformations, data validation, or simple
/// causal chains where history and external configuration are not needed.
///
/// It uses `CausalityError` for error handling and `EffectLog` for audit logging by default.
pub type PropagatingEffect<T> =
    CausalEffectPropagationProcess<T, (), (), CausalityError, EffectLog>;
