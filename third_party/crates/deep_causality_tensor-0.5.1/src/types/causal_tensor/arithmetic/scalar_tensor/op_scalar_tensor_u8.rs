/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// --- u8 ---
impl<'a> Add<&'a CausalTensor<u8>> for u8
where
    u8: Add<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn add(self, rhs: &'a CausalTensor<u8>) -> Self::Output {
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
impl Add<CausalTensor<u8>> for u8
where
    u8: Add<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn add(self, rhs: CausalTensor<u8>) -> Self::Output {
        self.add(&rhs)
    }
}
impl<'a> Sub<&'a CausalTensor<u8>> for u8
where
    u8: Sub<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn sub(self, rhs: &'a CausalTensor<u8>) -> Self::Output {
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
impl Sub<CausalTensor<u8>> for u8
where
    u8: Sub<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn sub(self, rhs: CausalTensor<u8>) -> Self::Output {
        self.sub(&rhs)
    }
}
impl<'a> Mul<&'a CausalTensor<u8>> for u8
where
    u8: Mul<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn mul(self, rhs: &'a CausalTensor<u8>) -> Self::Output {
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
impl Mul<CausalTensor<u8>> for u8
where
    u8: Mul<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn mul(self, rhs: CausalTensor<u8>) -> Self::Output {
        self.mul(&rhs)
    }
}
impl<'a> Div<&'a CausalTensor<u8>> for u8
where
    u8: Div<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn div(self, rhs: &'a CausalTensor<u8>) -> Self::Output {
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
impl Div<CausalTensor<u8>> for u8
where
    u8: Div<u8, Output = u8> + Clone,
{
    type Output = CausalTensor<u8>;
    fn div(self, rhs: CausalTensor<u8>) -> Self::Output {
        self.div(&rhs)
    }
}
