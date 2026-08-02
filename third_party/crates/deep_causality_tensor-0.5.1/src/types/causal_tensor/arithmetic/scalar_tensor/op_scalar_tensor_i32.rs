/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- i32 ---
impl<'a> Add<&'a CausalTensor<i32>> for i32
where
    i32: Add<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn add(self, rhs: &'a CausalTensor<i32>) -> Self::Output {
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
impl Add<CausalTensor<i32>> for i32
where
    i32: Add<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn add(self, rhs: CausalTensor<i32>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<i32>> for i32
where
    i32: Sub<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn sub(self, rhs: &'a CausalTensor<i32>) -> Self::Output {
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
impl Sub<CausalTensor<i32>> for i32
where
    i32: Sub<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn sub(self, rhs: CausalTensor<i32>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<i32>> for i32
where
    i32: Mul<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn mul(self, rhs: &'a CausalTensor<i32>) -> Self::Output {
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
impl Mul<CausalTensor<i32>> for i32
where
    i32: Mul<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn mul(self, rhs: CausalTensor<i32>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<i32>> for i32
where
    i32: Div<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn div(self, rhs: &'a CausalTensor<i32>) -> Self::Output {
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
impl Div<CausalTensor<i32>> for i32
where
    i32: Div<i32, Output = i32> + Clone,
{
    type Output = CausalTensor<i32>;
    fn div(self, rhs: CausalTensor<i32>) -> Self::Output {
        self.div(&rhs)
    }
}
