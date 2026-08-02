/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::ScalarEval;
use deep_causality_algebra::Normed;
use std::iter::Sum;

// `ScalarEval` is the multivector-side facade over `deep_causality_algebra::Normed`. Every scalar with
// a real modulus, every real float and `Complex<T>`, satisfies `Normed`, so this single blanket
// covers them all.
impl<T> ScalarEval for T
where
    T: Normed,
    T::Real: Sum,
{
    type Real = T::Real;

    #[inline]
    fn modulus_squared(&self) -> Self::Real {
        Normed::modulus_squared(self)
    }

    #[inline]
    fn scale_by_real(&self, s: Self::Real) -> Self {
        Normed::scale_by_real(self, s)
    }
}
