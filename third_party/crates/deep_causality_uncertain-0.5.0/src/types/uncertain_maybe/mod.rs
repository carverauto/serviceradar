/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
mod uncertain_maybe_bool;
mod uncertain_maybe_f106;
mod uncertain_maybe_f64;

use crate::{ProbabilisticType, Uncertain, UncertainError};

/// A first-class type representing a value that is probabilistically present or absent.
/// If the value is present, its own value is uncertain.
#[derive(Debug, Clone, PartialEq)]
pub struct MaybeUncertain<T: ProbabilisticType> {
    is_present: Uncertain<bool>,
    value: Uncertain<T>,
}

impl<T: ProbabilisticType> MaybeUncertain<T> {
    /// SPRT-gated collapse to a plain [`Uncertain<T>`], for any probabilistic value type.
    ///
    /// Acts as a presence gate: the value channel is returned only if the statistical
    /// evidence that the value is *present* meets the threshold; otherwise a
    /// [`UncertainError::PresenceError`] is returned. The presence test runs entirely on the
    /// type-independent `is_present` Bernoulli channel (`Uncertain<bool>::to_bool`), so the
    /// gate is identical at every precision — `f64`, `Float106`, `bool`, or any future
    /// `ProbabilisticType`. The presence parameters are dimensionless probabilities and stay
    /// `f64`.
    ///
    /// # Arguments
    /// * `threshold_prob_some` — presence probability the evidence must clear.
    /// * `confidence_level` — SPRT confidence (e.g. `0.95`).
    /// * `epsilon` — indifference region around the threshold.
    /// * `max_samples` — SPRT sampling budget.
    pub fn lift_to_uncertain(
        &self,
        threshold_prob_some: f64,
        confidence_level: f64,
        epsilon: f64,
        max_samples: usize,
    ) -> Result<Uncertain<T>, UncertainError> {
        let is_present =
            self.is_present
                .to_bool(threshold_prob_some, confidence_level, epsilon, max_samples)?;

        if is_present {
            Ok(self.value.clone())
        } else {
            Err(UncertainError::PresenceError(
                "Insufficient evidence for presence".to_string(),
            ))
        }
    }
}
