/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Generic constructors shared by every real-valued `Uncertain<T>` (`f64`, `Float106`).
//!
//! These are a **single** generic impl rather than one per precision, so a call like
//! `Uncertain::normal(0.0, 1.0)` still resolves `T = f64` by the usual `{float}` literal
//! fallback — existing f64 call sites compile unchanged. The per-type node-variant choice
//! is delegated to [`UncertainReal`].

use crate::{Uncertain, UncertainNodeContent, UncertainReal};

impl<T: UncertainReal> Uncertain<T> {
    /// A certain value, carried losslessly at `T`'s precision.
    pub fn point(value: T) -> Self {
        Self::from_root_node(UncertainNodeContent::Value(value.into_sampled_value()))
    }

    /// A normal (Gaussian) distribution at `T`'s precision.
    pub fn normal(mean: T, std_dev: T) -> Self {
        Self::from_root_node(T::normal_node(mean, std_dev))
    }

    /// A uniform distribution on `[low, high)` at `T`'s precision.
    pub fn uniform(low: T, high: T) -> Self {
        Self::from_root_node(T::uniform_node(low, high))
    }
}
