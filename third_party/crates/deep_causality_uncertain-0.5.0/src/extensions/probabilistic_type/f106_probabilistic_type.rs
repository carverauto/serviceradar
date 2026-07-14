/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    DistributionEnum, FromSampledValue, IntoSampledValue, NormalDistributionParams,
    ProbabilisticType, UncertainNodeContent, UncertainReal, UniformDistributionParams,
};
use crate::{SampledValue, UncertainError};
use deep_causality_num::Float106;

impl IntoSampledValue for Float106 {
    fn into_sampled_value(self) -> SampledValue {
        // Carry the full double-double value into its own variant — no narrowing to f64.
        SampledValue::DoubleFloat(self)
    }
}

impl FromSampledValue for Float106 {
    fn from_sampled_value(value: SampledValue) -> Result<Self, UncertainError> {
        match value {
            SampledValue::DoubleFloat(d) => Ok(d),
            // An f64 sample widens losslessly into a Float106 (low limb zero).
            SampledValue::Float(f) => Ok(Float106::from_f64(f)),
            _ => Err(UncertainError::UnsupportedTypeError(
                "Expected Float106 SampledValue".to_string(),
            )),
        }
    }
}

impl ProbabilisticType for Float106 {
    fn default_value() -> Self {
        Float106::from_f64(0.0)
    }
}

impl UncertainReal for Float106 {
    fn normal_node(mean: Self, std_dev: Self) -> UncertainNodeContent {
        UncertainNodeContent::DistributionF106(DistributionEnum::Normal(NormalDistributionParams {
            mean,
            std_dev,
        }))
    }

    fn uniform_node(low: Self, high: Self) -> UncertainNodeContent {
        UncertainNodeContent::DistributionF106(DistributionEnum::Uniform(
            UniformDistributionParams { low, high },
        ))
    }
}
