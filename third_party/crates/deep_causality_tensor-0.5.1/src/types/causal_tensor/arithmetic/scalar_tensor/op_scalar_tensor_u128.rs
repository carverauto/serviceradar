/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- u128 ---
impl<'a> Add<&'a CausalTensor<u128>> for u128
where
    u128: Add<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn add(self, rhs: &'a CausalTensor<u128>) -> Self::Output {
        let mut new_data = rhs.data.clone();
        for item in &mut new_data {
            *item = self.add(*item);
        }
        CausalTensor {
            data: new_data,
            shape: rhs.shape.clone(),
            strides: rhs.strides.clone(),
        }
    }
}
impl Add<CausalTensor<u128>> for u128
where
    u128: Add<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn add(self, rhs: CausalTensor<u128>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<u128>> for u128
where
    u128: Sub<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn sub(self, rhs: &'a CausalTensor<u128>) -> Self::Output {
        let mut new_data = rhs.data.clone();
        for item in &mut new_data {
            *item = self.sub(*item);
        }
        CausalTensor {
            data: new_data,
            shape: rhs.shape.clone(),
            strides: rhs.strides.clone(),
        }
    }
}
impl Sub<CausalTensor<u128>> for u128
where
    u128: Sub<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn sub(self, rhs: CausalTensor<u128>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<u128>> for u128
where
    u128: Mul<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn mul(self, rhs: &'a CausalTensor<u128>) -> Self::Output {
        let mut new_data = rhs.data.clone();
        for item in &mut new_data {
            *item = self.mul(*item);
        }
        CausalTensor {
            data: new_data,
            shape: rhs.shape.clone(),
            strides: rhs.strides.clone(),
        }
    }
}
impl Mul<CausalTensor<u128>> for u128
where
    u128: Mul<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn mul(self, rhs: CausalTensor<u128>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<u128>> for u128
where
    u128: Div<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn div(self, rhs: &'a CausalTensor<u128>) -> Self::Output {
        let mut new_data = rhs.data.clone();
        for item in &mut new_data {
            *item = self.div(*item);
        }
        CausalTensor {
            data: new_data,
            shape: rhs.shape.clone(),
            strides: rhs.strides.clone(),
        }
    }
}
impl Div<CausalTensor<u128>> for u128
where
    u128: Div<u128, Output = u128> + Clone,
{
    type Output = CausalTensor<u128>;
    fn div(self, rhs: CausalTensor<u128>) -> Self::Output {
        self.div(&rhs)
    }
}
