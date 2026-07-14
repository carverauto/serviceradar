/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use std::fmt::{Display, Formatter};

use crate::{FromSampledValue, IntoSampledValue, ProbabilisticType, UncertainError};

#[derive(Debug, Clone, Copy, PartialEq)]
/// Represents a sampled value that can be either a floating-point number or a boolean.
pub enum SampledValue {
    /// A floating-point sampled value.
    Float(f64),
    /// A boolean sampled value.
    Bool(bool),
}

impl Display for SampledValue {
    /// Formats the `SampledValue` for display.
    ///
    /// This implementation writes the underlying float or boolean value directly.
    ///
    /// # Arguments
    ///
    /// * `f` - The formatter to write into.
    ///
    /// # Returns
    ///
    /// A `std::fmt::Result` indicating success or failure of the formatting operation.
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            SampledValue::Float(value) => write!(f, "{}", value),
            SampledValue::Bool(value) => write!(f, "{}", value),
        }
    }
}

impl IntoSampledValue for SampledValue {
    fn into_sampled_value(self) -> SampledValue {
        self
    }
}

impl FromSampledValue for SampledValue {
    fn from_sampled_value(value: SampledValue) -> Result<Self, UncertainError> {
        Ok(value)
    }
}

impl ProbabilisticType for SampledValue {
    fn default_value() -> Self {
        SampledValue::Float(0.0)
    }
}
