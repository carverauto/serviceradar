/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- i64 ---
impl<'a> Add<&'a CausalTensor<i64>> for i64
where
    i64: Add<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn add(self, rhs: &'a CausalTensor<i64>) -> Self::Output {
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
impl Add<CausalTensor<i64>> for i64
where
    i64: Add<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn add(self, rhs: CausalTensor<i64>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<i64>> for i64
where
    i64: Sub<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn sub(self, rhs: &'a CausalTensor<i64>) -> Self::Output {
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
impl Sub<CausalTensor<i64>> for i64
where
    i64: Sub<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn sub(self, rhs: CausalTensor<i64>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<i64>> for i64
where
    i64: Mul<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn mul(self, rhs: &'a CausalTensor<i64>) -> Self::Output {
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
impl Mul<CausalTensor<i64>> for i64
where
    i64: Mul<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn mul(self, rhs: CausalTensor<i64>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<i64>> for i64
where
    i64: Div<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn div(self, rhs: &'a CausalTensor<i64>) -> Self::Output {
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
impl Div<CausalTensor<i64>> for i64
where
    i64: Div<i64, Output = i64> + Clone,
{
    type Output = CausalTensor<i64>;
    fn div(self, rhs: CausalTensor<i64>) -> Self::Output {
        self.div(&rhs)
    }
}
