/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    DistributionEnum, FromSampledValue, IntoSampledValue, NormalDistributionParams,
    ProbabilisticType, UncertainNodeContent, UncertainReal, UniformDistributionParams,
};
use crate::{SampledValue, UncertainError};
use deep_causality_num::ToPrimitive;

impl IntoSampledValue for f64 {
    fn into_sampled_value(self) -> SampledValue {
        SampledValue::Float(self.to_f64().unwrap_or(f64::NAN))
    }
}

impl FromSampledValue for f64 {
    fn from_sampled_value(value: SampledValue) -> Result<Self, UncertainError> {
        match value {
            SampledValue::Float(f) => Ok(f),
            _ => Err(UncertainError::UnsupportedTypeError(
                "Expected f64 SampledValue".to_string(),
            )),
        }
    }
}

impl ProbabilisticType for f64 {
    fn default_value() -> Self {
        f64::default()
    }
}

impl UncertainReal for f64 {
    fn normal_node(mean: Self, std_dev: Self) -> UncertainNodeContent {
        UncertainNodeContent::DistributionF64(DistributionEnum::Normal(NormalDistributionParams {
            mean,
            std_dev,
        }))
    }

    fn uniform_node(low: Self, high: Self) -> UncertainNodeContent {
        UncertainNodeContent::DistributionF64(DistributionEnum::Uniform(
            UniformDistributionParams { low, high },
        ))
    }
}
