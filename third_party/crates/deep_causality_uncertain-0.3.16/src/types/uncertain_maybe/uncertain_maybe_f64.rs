/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{MaybeUncertain, Uncertain, UncertainError};
use std::ops::{Add, Div, Mul, Neg, Sub};

impl MaybeUncertain<f64> {
    /// Creates a new `MaybeUncertain` from a value that is certainly present but uncertain in value.
    pub fn from_uncertain(value: Uncertain<f64>) -> Self {
        Self {
            is_present: Uncertain::<bool>::point(true),
            value,
        }
    }

    /// Creates a new `MaybeUncertain` from a value that is certainly present and has a certain value.
    pub fn from_value(value: f64) -> Self {
        Self {
            is_present: Uncertain::<bool>::point(true),
            value: Uncertain::<f64>::point(value),
        }
    }

    /// Creates a new `MaybeUncertain` that is certainly absent.
    pub fn always_none() -> Self {
        Self {
            is_present: Uncertain::<bool>::point(false),
            value: Uncertain::<f64>::point(0.0), // This value will never be used
        }
    }

    /// Creates a `MaybeUncertain` where presence is determined by a Bernoulli trial.
    pub fn from_bernoulli_and_uncertain(
        prob_some: f64,
        present_value_dist: Uncertain<f64>,
    ) -> Self {
        Self {
            is_present: Uncertain::bernoulli(prob_some),
            value: present_value_dist,
        }
    }

    /// Samples the `MaybeUncertain` value, returning `Some(f64)` if present or `None` if absent.
    pub fn sample(&self) -> Result<Option<f64>, UncertainError> {
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

    /// Converts the `MaybeUncertain<f64>` to a standard `Uncertain<f64>`.
    ///
    /// This acts as a gate, returning `Ok(Uncertain<f64>)` only if the statistical evidence
    /// for the value's presence meets the specified threshold.
    pub fn lift_to_uncertain(
        &self,
        threshold_prob_some: f64,
        confidence_level: f64,
        epsilon: f64,       // 0.05
        max_samples: usize, // 1000
    ) -> Result<Uncertain<f64>, UncertainError> {
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

// Ops traits implementations
impl Add for MaybeUncertain<f64> {
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        Self {
            is_present: self.is_present & rhs.is_present,
            value: self.value + rhs.value,
        }
    }
}

impl Sub for MaybeUncertain<f64> {
    type Output = Self;

    fn sub(self, rhs: Self) -> Self::Output {
        Self {
            is_present: self.is_present & rhs.is_present,
            value: self.value - rhs.value,
        }
    }
}

impl Mul for MaybeUncertain<f64> {
    type Output = Self;

    fn mul(self, rhs: Self) -> Self::Output {
        Self {
            is_present: self.is_present & rhs.is_present,
            value: self.value * rhs.value,
        }
    }
}

impl Div for MaybeUncertain<f64> {
    type Output = Self;

    fn div(self, rhs: Self) -> Self::Output {
        Self {
            is_present: self.is_present & rhs.is_present,
            value: self.value / rhs.value,
        }
    }
}

impl Neg for MaybeUncertain<f64> {
    type Output = Self;

    fn neg(self) -> Self::Output {
        Self {
            is_present: self.is_present,
            value: -self.value,
        }
    }
}
