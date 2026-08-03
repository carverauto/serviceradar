/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Dual, Real, Zero};

// The default dual number is the additive identity `0 + 0·ε` — a constant zero
// carrying a zero derivative. This coincides with `Zero::zero`, so `Default` and
// `Zero` agree, and needs only `T: Real` (no `T: Default` bound): the components
// come from `T::zero()`, matching the `Zero` impl in `identity.rs`.
impl<T: Real> Default for Dual<T> {
    #[inline]
    fn default() -> Self {
        Self::zero()
    }
}
