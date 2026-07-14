/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AggregateLogic, CausalityError, CausalityErrorEnum};
use deep_causality_core::EffectValue;
use deep_causality_uncertain::{Uncertain, UncertainBool, UncertainF64};

/// Defines how to aggregate a collection of effects of type T.
pub trait Aggregatable: Sized {
    fn aggregate(
        effects: &[EffectValue<Self>],
        logic: &AggregateLogic,
        threshold: Option<f64>,
    ) -> Result<EffectValue<Self>, CausalityError>;
}

/// Main dispatcher function for aggregation.
pub fn aggregate_effects<T: Aggregatable>(
    effects: &[EffectValue<T>],
    logic: &AggregateLogic,
    threshold_value: Option<f64>,
) -> Result<EffectValue<T>, CausalityError> {
    if effects.is_empty() {
        return Err(CausalityError::new(CausalityErrorEnum::Custom(
            "Cannot aggregate empty collection".to_string(),
        )));
    }
    T::aggregate(effects, logic, threshold_value)
}

impl Aggregatable for bool {
    fn aggregate(
        effects: &[EffectValue<bool>],
        logic: &AggregateLogic,
        _threshold: Option<f64>,
    ) -> Result<EffectValue<bool>, CausalityError> {
        let bools: Result<Vec<bool>, _> = effects
            .iter()
            .map(|e| match e {
                EffectValue::Value(b) => Ok(*b),
                _ => Err(CausalityError::new(CausalityErrorEnum::Custom(format!(
                    "Expected Value(bool), found {:?}",
                    e
                )))),
            })
            .collect();

        let bools = bools?;
        let final_bool = match logic {
            AggregateLogic::All => bools.iter().all(|&b| b),
            AggregateLogic::Any => bools.iter().any(|&b| b),
            AggregateLogic::None => bools.iter().all(|&b| !b),
            AggregateLogic::Some(k) => bools.iter().filter(|&&b| b).count() >= *k,
        };
        Ok(EffectValue::Value(final_bool))
    }
}

impl Aggregatable for f64 {
    fn aggregate(
        effects: &[EffectValue<f64>],
        logic: &AggregateLogic,
        _threshold: Option<f64>,
    ) -> Result<EffectValue<f64>, CausalityError> {
        let probs: Result<Vec<f64>, _> = effects
            .iter()
            .map(|e| match e {
                EffectValue::Value(p) => Ok(*p),
                _ => Err(CausalityError::new(CausalityErrorEnum::Custom(format!(
                    "Expected Value(f64), found {:?}",
                    e
                )))),
            })
            .collect();

        let probs = probs?;
        let final_prob = match logic {
            AggregateLogic::All => probs.iter().product(),
            AggregateLogic::Any => 1.0 - probs.iter().map(|p| 1.0 - p).product::<f64>(),
            AggregateLogic::None => probs.iter().map(|p| 1.0 - p).product::<f64>(),
            AggregateLogic::Some(k) => {
                let count = probs.iter().filter(|&&p| p > 0.5).count();
                if count >= *k { 1.0 } else { 0.0 }
            }
        };
        Ok(EffectValue::Value(final_prob))
    }
}

impl Aggregatable for UncertainBool {
    fn aggregate(
        effects: &[EffectValue<UncertainBool>],
        logic: &AggregateLogic,
        threshold: Option<f64>,
    ) -> Result<EffectValue<UncertainBool>, CausalityError> {
        let threshold = threshold.ok_or_else(|| {
            CausalityError::new(CausalityErrorEnum::Custom(
                "Threshold is required for uncertain aggregation".to_string(),
            ))
        })?;

        let u_bools: Result<Vec<UncertainBool>, _> = effects
            .iter()
            .map(|e| match e {
                EffectValue::Value(ub) => Ok(ub.clone()),
                _ => Err(CausalityError::new(CausalityErrorEnum::Custom(format!(
                    "Expected Value(UncertainBool), found {:?}",
                    e
                )))),
            })
            .collect();

        let u_bools = u_bools?;
        let final_ubool = match logic {
            AggregateLogic::All => {
                u_bools
                    .into_iter()
                    .reduce(|acc, u| acc & u)
                    .ok_or_else(|| {
                        CausalityError::new(CausalityErrorEnum::Custom("Empty reduction".into()))
                    })?
            }
            AggregateLogic::Any => {
                u_bools
                    .into_iter()
                    .reduce(|acc, u| acc | u)
                    .ok_or_else(|| {
                        CausalityError::new(CausalityErrorEnum::Custom("Empty reduction".into()))
                    })?
            }
            AggregateLogic::None => {
                let res = u_bools
                    .into_iter()
                    .reduce(|acc, u| acc | u)
                    .ok_or_else(|| {
                        CausalityError::new(CausalityErrorEnum::Custom("Empty reduction".into()))
                    })?;
                !res
            }
            AggregateLogic::Some(k) => {
                let bools: Result<Vec<bool>, _> = u_bools
                    .iter()
                    .map(|u| u.to_bool(threshold, 0.95, 0.05, 1000))
                    .collect();
                let true_count = bools
                    .map_err(|e| CausalityError::new(CausalityErrorEnum::Custom(e.to_string())))?
                    .iter()
                    .filter(|&&b| b)
                    .count();
                Uncertain::<bool>::point(true_count >= *k)
            }
        };
        Ok(EffectValue::Value(final_ubool))
    }
}

impl Aggregatable for UncertainF64 {
    fn aggregate(
        _effects: &[EffectValue<UncertainF64>],
        _logic: &AggregateLogic,
        _threshold: Option<f64>,
    ) -> Result<EffectValue<UncertainF64>, CausalityError> {
        Err(CausalityError::new(CausalityErrorEnum::Custom(
            "Direct aggregation of UncertainF64 is not supported. Convert to UncertainBool first."
                .to_string(),
        )))
    }
}
