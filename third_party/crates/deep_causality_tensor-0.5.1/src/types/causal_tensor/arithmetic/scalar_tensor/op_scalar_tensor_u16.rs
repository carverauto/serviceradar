/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- u16 ---
impl<'a> Add<&'a CausalTensor<u16>> for u16
where
    u16: Add<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn add(self, rhs: &'a CausalTensor<u16>) -> Self::Output {
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
impl Add<CausalTensor<u16>> for u16
where
    u16: Add<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn add(self, rhs: CausalTensor<u16>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<u16>> for u16
where
    u16: Sub<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn sub(self, rhs: &'a CausalTensor<u16>) -> Self::Output {
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
impl Sub<CausalTensor<u16>> for u16
where
    u16: Sub<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn sub(self, rhs: CausalTensor<u16>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<u16>> for u16
where
    u16: Mul<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn mul(self, rhs: &'a CausalTensor<u16>) -> Self::Output {
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
impl Mul<CausalTensor<u16>> for u16
where
    u16: Mul<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn mul(self, rhs: CausalTensor<u16>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<u16>> for u16
where
    u16: Div<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn div(self, rhs: &'a CausalTensor<u16>) -> Self::Output {
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
impl Div<CausalTensor<u16>> for u16
where
    u16: Div<u16, Output = u16> + Clone,
{
    type Output = CausalTensor<u16>;
    fn div(self, rhs: CausalTensor<u16>) -> Self::Output {
        self.div(&rhs)
    }
}
