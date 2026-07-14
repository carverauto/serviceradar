/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use std::fmt::{Display, Formatter};

use crate::{FromSampledValue, IntoSampledValue, ProbabilisticType, UncertainError};
use deep_causality_num::Float106;

#[derive(Debug, Clone, Copy, PartialEq)]
/// A sampled value: the closed precision dispatcher for the uncertain engine.
///
/// `SampledValue` carries the value's precision as a variant rather than a type
/// parameter, so the computation graph, the global sample cache (a `static`), and the
/// sampler all stay non-generic while still propagating `Float106` precision end to end.
/// The boundary types (`Uncertain<R>` / `MaybeUncertain<R>`) are generic over
/// `R: RealField` and convert to/from the matching variant via `ProbabilisticType`.
pub enum SampledValue {
    /// An `f64` sampled value.
    Float(f64),
    /// A `Float106` (double-double, ~106-bit) sampled value, kept distinct from `Float`
    /// so the high-precision path never narrows through `f64`.
    DoubleFloat(Float106),
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
            SampledValue::DoubleFloat(value) => write!(f, "{}", value),
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
