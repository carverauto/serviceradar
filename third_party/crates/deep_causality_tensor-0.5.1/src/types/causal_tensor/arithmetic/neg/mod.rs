/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensor;
use std::ops::Neg;

/// Implements Neg trait for CausalTensor.
impl<T> Neg for CausalTensor<T>
where
    T: Neg<Output = T> + Copy + Clone,
{
    type Output = Self;

    fn neg(self) -> Self::Output {
        let data = self.data.iter().map(|x| -*x).collect();
        Self::from_vec_and_shape_unchecked(data, self.shape())
    }
}

impl<T> Neg for &CausalTensor<T>
where
    T: Neg<Output = T> + Copy + Clone,
{
    type Output = CausalTensor<T>;

    fn neg(self) -> Self::Output {
        let data = self.data.iter().map(|x| -*x).collect();
        CausalTensor::from_vec_and_shape_unchecked(data, self.shape())
    }
}
