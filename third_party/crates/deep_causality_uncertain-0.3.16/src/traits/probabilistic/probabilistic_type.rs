/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{SampledValue, UncertainError};

pub trait IntoSampledValue {
    /// Converts the type into an internal `SampledValue` representation.
    fn into_sampled_value(self) -> SampledValue;
}

pub trait FromSampledValue
where
    Self: Sized,
{
    /// Attempts to convert an internal `SampledValue` back into this type.
    fn from_sampled_value(value: SampledValue) -> Result<Self, UncertainError>;
}

pub trait ProbabilisticType:
    IntoSampledValue + FromSampledValue + Clone + Send + Sync + 'static
{
    /// Provides a default or zero-equivalent value for the type.
    fn default_value() -> Self;
}
