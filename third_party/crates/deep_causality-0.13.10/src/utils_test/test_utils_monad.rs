/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalityError, CausalityErrorEnum, EffectLog, EffectValue, PropagatingEffect};
use deep_causality_haft::LogAddEntry;

// f(U_smoking) -> Smoking
// Input: Nicotine level (f64)
// Output: High Nicotine (bool)
pub fn smoking_logic(
    nicotine_obs: EffectValue<f64>,
    _state: (),
    _ctx: Option<()>,
) -> PropagatingEffect<bool> {
    let mut log = EffectLog::new();
    let nicotine_val = nicotine_obs.into_value().unwrap_or(0.0);
    let threshold = 0.6;
    let high_nicotine = nicotine_val > threshold;
    log.add_entry(&format!(
        "Nicotine level {} is higher than threshold {}: {}",
        nicotine_val, threshold, high_nicotine
    ));

    let mut effect = PropagatingEffect::pure(high_nicotine);
    effect.logs = log;
    effect
}

// f(Smoking) -> Tar
// Input: Is Smoking (bool)
// Output: Has Tar (bool)
pub fn tar_logic(
    is_smoking: EffectValue<bool>,
    _state: (),
    _ctx: Option<()>,
) -> PropagatingEffect<bool> {
    let mut log = EffectLog::new();
    let smoking = is_smoking.into_value().unwrap_or(false);
    log.add_entry(&format!("Has tar in lung {}", smoking));

    let mut effect = PropagatingEffect::pure(smoking);
    effect.logs = log;
    effect
}

pub fn error_logic(
    _val: EffectValue<bool>,
    _state: (),
    _ctx: Option<()>,
) -> PropagatingEffect<bool> {
    let mut log = EffectLog::new();
    log.add_entry("Error logic applied");

    let mut effect = PropagatingEffect::from_error(CausalityError::new(
        CausalityErrorEnum::Custom("Simulated error".to_string()),
    ));
    effect.logs = log;
    effect
}
