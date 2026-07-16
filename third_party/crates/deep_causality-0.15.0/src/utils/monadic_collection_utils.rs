/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AggregateLogic, CausalityError, CausalityErrorEnum};
use deep_causality_algebra::Verdict;
use deep_causality_core::CausalEffect;
use deep_causality_uncertain::{Uncertain, UncertainBool, UncertainF64};

/// Defines how to aggregate a collection of effects of type T.
///
/// **Carrier bound (`Verdict`).** Aggregation is only defined over a lawful verdict algebra — a
/// bounded lattice with complement — so `Verdict` is a supertrait: `All`/`Any`/`None`/`Some(k)`
/// are closed operations in that algebra, which is what makes a collection of causaloids again a
/// causaloid (`core.verdict.closure`, `lean/DeepCausalityFormal/Core/VerdictClosure.lean`;
/// assumption #5). Implementing `Aggregatable` for a carrier with no `Verdict` instance is a
/// compile error:
///
/// ```compile_fail
/// use deep_causality::{Aggregatable, AggregateLogic, CausalityError};
/// use deep_causality_core::CausalEffect;
///
/// struct NotAVerdict(u8);
///
/// // error[E0277]: the trait bound `NotAVerdict: Verdict` is not satisfied
/// impl Aggregatable for NotAVerdict {
///     fn aggregate(
///         _effects: &[CausalEffect<Self>],
///         _logic: &AggregateLogic,
///         _threshold: Option<f64>,
///     ) -> Result<CausalEffect<Self>, CausalityError> {
///         unimplemented!()
///     }
/// }
/// ```
///
/// Migration: implement [`Verdict`] for your carrier (`bottom`/`top`/`meet`/`join`/`complement`,
/// lawful per `num.verdict.*`), or aggregate into a shipped carrier (`bool`, `f64`,
/// `UncertainBool`, `UncertainF64`).
pub trait Aggregatable: Verdict + Sized {
    fn aggregate(
        effects: &[CausalEffect<Self>],
        logic: &AggregateLogic,
        threshold: Option<f64>,
    ) -> Result<CausalEffect<Self>, CausalityError>;
}

/// Main dispatcher function for aggregation.
pub fn aggregate_effects<T: Aggregatable>(
    effects: &[CausalEffect<T>],
    logic: &AggregateLogic,
    threshold_value: Option<f64>,
) -> Result<CausalEffect<T>, CausalityError> {
    if effects.is_empty() {
        return Err(CausalityError::new(CausalityErrorEnum::Custom(
            "Cannot aggregate empty collection".to_string(),
        )));
    }
    T::aggregate(effects, logic, threshold_value)
}

impl Aggregatable for bool {
    fn aggregate(
        effects: &[CausalEffect<bool>],
        logic: &AggregateLogic,
        _threshold: Option<f64>,
    ) -> Result<CausalEffect<bool>, CausalityError> {
        let bools: Result<Vec<bool>, _> = effects
            .iter()
            .map(|e| {
                e.as_value().copied().ok_or_else(|| {
                    CausalityError::new(CausalityErrorEnum::Custom(format!(
                        "Expected Value(bool), found {:?}",
                        e
                    )))
                })
            })
            .collect();

        let bools = bools?;
        let final_bool = match logic {
            AggregateLogic::All => bools.iter().all(|&b| b),
            AggregateLogic::Any => bools.iter().any(|&b| b),
            AggregateLogic::None => bools.iter().all(|&b| !b),
            AggregateLogic::Some(k) => bools.iter().filter(|&&b| b).count() >= *k,
        };
        Ok(CausalEffect::value(final_bool))
    }
}

impl Aggregatable for f64 {
    fn aggregate(
        effects: &[CausalEffect<f64>],
        logic: &AggregateLogic,
        _threshold: Option<f64>,
    ) -> Result<CausalEffect<f64>, CausalityError> {
        let probs: Result<Vec<f64>, _> = effects
            .iter()
            .map(|e| {
                e.as_value().copied().ok_or_else(|| {
                    CausalityError::new(CausalityErrorEnum::Custom(format!(
                        "Expected Value(f64), found {:?}",
                        e
                    )))
                })
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
        Ok(CausalEffect::value(final_prob))
    }
}

impl Aggregatable for UncertainBool {
    fn aggregate(
        effects: &[CausalEffect<UncertainBool>],
        logic: &AggregateLogic,
        threshold: Option<f64>,
    ) -> Result<CausalEffect<UncertainBool>, CausalityError> {
        let threshold = threshold.ok_or_else(|| {
            CausalityError::new(CausalityErrorEnum::Custom(
                "Threshold is required for uncertain aggregation".to_string(),
            ))
        })?;

        let u_bools: Result<Vec<UncertainBool>, _> = effects
            .iter()
            .map(|e| {
                e.as_value().cloned().ok_or_else(|| {
                    CausalityError::new(CausalityErrorEnum::Custom(format!(
                        "Expected Value(UncertainBool), found {:?}",
                        e
                    )))
                })
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
        Ok(CausalEffect::value(final_ubool))
    }
}

impl Aggregatable for UncertainF64 {
    fn aggregate(
        _effects: &[CausalEffect<UncertainF64>],
        _logic: &AggregateLogic,
        _threshold: Option<f64>,
    ) -> Result<CausalEffect<UncertainF64>, CausalityError> {
        Err(CausalityError::new(CausalityErrorEnum::Custom(
            "Direct aggregation of UncertainF64 is not supported. Convert to UncertainBool first."
                .to_string(),
        )))
    }
}
