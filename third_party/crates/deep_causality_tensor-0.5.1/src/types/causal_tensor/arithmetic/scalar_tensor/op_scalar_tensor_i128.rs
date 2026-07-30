/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- i128 ---
impl<'a> Add<&'a CausalTensor<i128>> for i128
where
    i128: Add<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn add(self, rhs: &'a CausalTensor<i128>) -> Self::Output {
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
impl Add<CausalTensor<i128>> for i128
where
    i128: Add<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn add(self, rhs: CausalTensor<i128>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<i128>> for i128
where
    i128: Sub<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn sub(self, rhs: &'a CausalTensor<i128>) -> Self::Output {
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
impl Sub<CausalTensor<i128>> for i128
where
    i128: Sub<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn sub(self, rhs: CausalTensor<i128>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<i128>> for i128
where
    i128: Mul<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn mul(self, rhs: &'a CausalTensor<i128>) -> Self::Output {
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
impl Mul<CausalTensor<i128>> for i128
where
    i128: Mul<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn mul(self, rhs: CausalTensor<i128>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<i128>> for i128
where
    i128: Div<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn div(self, rhs: &'a CausalTensor<i128>) -> Self::Output {
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
impl Div<CausalTensor<i128>> for i128
where
    i128: Div<i128, Output = i128> + Clone,
{
    type Output = CausalTensor<i128>;
    fn div(self, rhs: CausalTensor<i128>) -> Self::Output {
        self.div(&rhs)
    }
}
