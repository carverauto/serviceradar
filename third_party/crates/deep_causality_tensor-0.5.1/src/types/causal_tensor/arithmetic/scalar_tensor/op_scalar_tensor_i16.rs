/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- i16 ---
impl<'a> Add<&'a CausalTensor<i16>> for i16
where
    i16: Add<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn add(self, rhs: &'a CausalTensor<i16>) -> Self::Output {
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
impl Add<CausalTensor<i16>> for i16
where
    i16: Add<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn add(self, rhs: CausalTensor<i16>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<i16>> for i16
where
    i16: Sub<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn sub(self, rhs: &'a CausalTensor<i16>) -> Self::Output {
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
impl Sub<CausalTensor<i16>> for i16
where
    i16: Sub<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn sub(self, rhs: CausalTensor<i16>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<i16>> for i16
where
    i16: Mul<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn mul(self, rhs: &'a CausalTensor<i16>) -> Self::Output {
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
impl Mul<CausalTensor<i16>> for i16
where
    i16: Mul<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn mul(self, rhs: CausalTensor<i16>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<i16>> for i16
where
    i16: Div<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn div(self, rhs: &'a CausalTensor<i16>) -> Self::Output {
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
impl Div<CausalTensor<i16>> for i16
where
    i16: Div<i16, Output = i16> + Clone,
{
    type Output = CausalTensor<i16>;
    fn div(self, rhs: CausalTensor<i16>) -> Self::Output {
        self.div(&rhs)
    }
}
