/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{FromSampledValue, IntoSampledValue, ProbabilisticType};
use crate::{SampledValue, UncertainError};

impl IntoSampledValue for bool {
    fn into_sampled_value(self) -> SampledValue {
        SampledValue::Bool(self)
    }
}

impl FromSampledValue for bool {
    fn from_sampled_value(value: SampledValue) -> Result<Self, UncertainError> {
        match value {
            SampledValue::Bool(b) => Ok(b),
            _ => Err(UncertainError::UnsupportedTypeError(
                "Expected bool SampledValue".to_string(),
            )),
        }
    }
}

impl ProbabilisticType for bool {
    fn default_value() -> Self {
        false
    }
}
