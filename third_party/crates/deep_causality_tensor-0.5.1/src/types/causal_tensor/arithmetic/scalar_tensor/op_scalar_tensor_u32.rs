/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- u32 ---
impl<'a> Add<&'a CausalTensor<u32>> for u32
where
    u32: Add<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn add(self, rhs: &'a CausalTensor<u32>) -> Self::Output {
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
impl Add<CausalTensor<u32>> for u32
where
    u32: Add<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn add(self, rhs: CausalTensor<u32>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<u32>> for u32
where
    u32: Sub<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn sub(self, rhs: &'a CausalTensor<u32>) -> Self::Output {
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
impl Sub<CausalTensor<u32>> for u32
where
    u32: Sub<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn sub(self, rhs: CausalTensor<u32>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<u32>> for u32
where
    u32: Mul<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn mul(self, rhs: &'a CausalTensor<u32>) -> Self::Output {
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
impl Mul<CausalTensor<u32>> for u32
where
    u32: Mul<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn mul(self, rhs: CausalTensor<u32>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<u32>> for u32
where
    u32: Div<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn div(self, rhs: &'a CausalTensor<u32>) -> Self::Output {
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
impl Div<CausalTensor<u32>> for u32
where
    u32: Div<u32, Output = u32> + Clone,
{
    type Output = CausalTensor<u32>;
    fn div(self, rhs: CausalTensor<u32>) -> Self::Output {
        self.div(&rhs)
    }
}
