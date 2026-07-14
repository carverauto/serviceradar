/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float;
use core::fmt::Debug;

/// A trait to abstract over float types (`f32`, `f64`) and their `Option` variants.
///
/// It provides a unified way to convert these types into an `Option<F>`
/// where `F` is a type that implements the `Float` trait.
pub trait FloatOption<F: Float>: Clone + Debug + Send + Sync + 'static {
    /// Converts the implementing type into an `Option<F>`.
    ///
    /// - For a float type `F`, `NaN` is treated as a missing value (`None`).
    /// - For `Option<F>`, this handles `Some(NaN)` by returning `None`, and passes through `Some(value)` and `None`.
    fn to_option(&self) -> Option<F>;
}

// Implementation for any `F` that implements `Float`.
// This covers `f32` and `f64`.
impl<F> FloatOption<F> for F
where
    F: Float + Debug + Send + Sync + 'static,
{
    fn to_option(&self) -> Option<F> {
        if self.is_nan() { None } else { Some(*self) }
    }
}

// Implementation for `Option<F>`.
// This covers `Option<f32>` and `Option<f64>`.
impl<F> FloatOption<F> for Option<F>
where
    F: Float + Debug + Send + Sync + 'static,
{
    fn to_option(&self) -> Option<F> {
        self.and_then(|value| if value.is_nan() { None } else { Some(value) })
    }
}
