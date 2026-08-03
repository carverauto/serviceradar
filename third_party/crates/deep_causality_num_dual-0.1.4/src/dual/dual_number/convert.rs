/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Dual, Real};

/// A real literal converts to a **constant** dual (`x + 0·ε`): a constant has zero
/// derivative by definition.
///
/// This lets `Dual<T>` flow through generic code bounded on `From<f64>` — kernels that
/// build their constants with `R::from(0.5)` and the like — so forward-mode automatic
/// differentiation reaches arithmetic otherwise driven by `f64` literals, without those
/// literals contaminating the `ε` channel.
impl<T: Real + From<f64>> From<f64> for Dual<T> {
    #[inline]
    fn from(value: f64) -> Self {
        Dual::constant(T::from(value))
    }
}
