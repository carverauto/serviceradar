/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensor;
use deep_causality_num::{One, Zero};

/// Implements Zero trait for CausalTensor.
/// Returns a scalar zero tensor (shape []).
/// This allows broadcasting to work for addition (a + 0 = a).
impl<T> Zero for CausalTensor<T>
where
    T: Zero + Copy + Default + PartialOrd,
{
    fn zero() -> Self {
        // Scalar zero tensor
        Self::new(vec![T::zero()], vec![]).expect("Failed to create zero scalar tensor")
    }

    fn is_zero(&self) -> bool {
        self.data.iter().all(|x| x.is_zero())
    }
}

impl<T> One for CausalTensor<T>
where
    T: One + Copy + Default + PartialOrd,
{
    fn one() -> Self {
        // Scalar one tensor
        Self::new(vec![T::one()], vec![]).expect("Failed to create one scalar tensor")
    }

    fn is_one(&self) -> bool {
        self.data.iter().all(|x| x.is_one())
    }
}
