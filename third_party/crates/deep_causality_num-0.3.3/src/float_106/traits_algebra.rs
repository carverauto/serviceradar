/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Identity and numeric trait implementations for `Float106`.
//!
//! Only the traits that sit *below* `Float` in the tower are implemented here:
//! `Zero`, `One`, and `Num`. Everything above `Float` — the markers
//! (`Associative`/`Commutative`/`Distributive`), `AbelianGroup`, `DivisionAlgebra`,
//! `Real`, and `RealField` — is provided automatically by the blanket impls over
//! `Float` (e.g. `impl<T: Float> Real for T`), since `Float106` implements `Float`.

use crate::Float106;
use crate::{Num, One, Zero};

// =============================================================================
// Identity Traits
// =============================================================================

impl Zero for Float106 {
    #[inline]
    fn zero() -> Self {
        Self::from_f64(0.0)
    }

    #[inline]
    fn is_zero(&self) -> bool {
        self.hi() == 0.0 && self.lo() == 0.0
    }
}

impl One for Float106 {
    #[inline]
    fn one() -> Self {
        Self::from_f64(1.0)
    }

    #[inline]
    fn is_one(&self) -> bool {
        self.hi() == 1.0 && self.lo() == 0.0
    }
}

// =============================================================================
// Numeric Trait
// =============================================================================

impl Num for Float106 {}
