/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{MaybeUncertain, Uncertain, UncertainError};

impl MaybeUncertain<bool> {
    pub fn from_uncertain(value: Uncertain<bool>) -> Self {
        Self {
            is_present: Uncertain::<bool>::point(true),
            value,
        }
    }

    /// Creates a new `MaybeUncertain` from a value that is certainly present and has a certain value.
    pub fn from_value(value: bool) -> Self {
        Self {
            is_present: Uncertain::<bool>::point(true),
            value: Uncertain::<bool>::point(value),
        }
    }

    /// Creates a new `MaybeUncertain` that is certainly absent.
    pub fn always_none() -> Self {
        Self {
            is_present: Uncertain::<bool>::point(false),
            value: Uncertain::<bool>::point(false), // This value will never be used
        }
    }

    /// Creates a `MaybeUncertain` where presence is determined by a Bernoulli trial.
    pub fn from_bernoulli_and_uncertain(
        prob_some: f64,
        present_value_dist: Uncertain<bool>,
    ) -> Self {
        Self {
            is_present: Uncertain::bernoulli(prob_some),
            value: present_value_dist,
        }
    }

    /// Samples the `MaybeUncertain` value, returning `Some(bool)` if present or `None` if absent.
    pub fn sample(&self) -> Result<Option<bool>, UncertainError> {
        if self.is_present.sample()? {
            Ok(Some(self.value.sample()?))
        } else {
            Ok(None)
        }
    }

    /// Returns an `Uncertain<bool>` representing the probability of the value being present.
    pub fn is_some(&self) -> Uncertain<bool> {
        self.is_present.clone()
    }

    /// Returns an `Uncertain<bool>` representing the probability of the value being absent.
    pub fn is_none(&self) -> Uncertain<bool> {
        !self.is_present.clone()
    }

    /// Converts the `MaybeUncertain<bool>` to a standard `Uncertain<bool>`.
    ///
    /// This acts as a gate, returning `Ok(Uncertain<bool>)` only if the statistical evidence
    /// for the value's presence meets the specified threshold.
    pub fn lift_to_uncertain(
        &self,
        threshold_prob_some: f64,
        confidence_level: f64,
        epsilon: f64,       // 0.05
        max_samples: usize, // 1000
    ) -> Result<Uncertain<bool>, UncertainError> {
        let is_present = self.is_present.to_bool(
            threshold_prob_some,
            confidence_level,
            epsilon, // Default epsilon
            max_samples,
        )?;

        if is_present {
            Ok(self.value.clone())
        } else {
            Err(UncertainError::PresenceError(
                "Insufficient evidence for presence".to_string(),
            ))
        }
    }
}
