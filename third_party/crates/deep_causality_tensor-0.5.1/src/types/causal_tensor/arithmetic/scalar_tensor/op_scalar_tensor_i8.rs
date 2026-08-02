/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// ############################################################################
// ############################### ADDITION ###################################
// ############################################################################

// --- i8 ---
impl<'a> Add<&'a CausalTensor<i8>> for i8
where
    i8: Add<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;

    fn add(self, rhs: &'a CausalTensor<i8>) -> Self::Output {
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

impl Add<CausalTensor<i8>> for i8
where
    i8: Add<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;
    fn add(self, rhs: CausalTensor<i8>) -> Self::Output {
        self.add(&rhs)
    }
}

// ############################################################################
// ############################## SUBTRACTION #################################
// ############################################################################

// --- i8 ---
impl<'a> Sub<&'a CausalTensor<i8>> for i8
where
    i8: Sub<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;

    fn sub(self, rhs: &'a CausalTensor<i8>) -> Self::Output {
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

impl Sub<CausalTensor<i8>> for i8
where
    i8: Sub<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;
    fn sub(self, rhs: CausalTensor<i8>) -> Self::Output {
        self.sub(&rhs)
    }
}

// ############################################################################
// ############################ MULTIPLICATION ################################
// ############################################################################

// --- i8 ---
impl<'a> Mul<&'a CausalTensor<i8>> for i8
where
    i8: Mul<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;

    fn mul(self, rhs: &'a CausalTensor<i8>) -> Self::Output {
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

impl Mul<CausalTensor<i8>> for i8
where
    i8: Mul<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;
    fn mul(self, rhs: CausalTensor<i8>) -> Self::Output {
        self.mul(&rhs)
    }
}

// ############################################################################
// ############################### DIVISION ###################################
// ############################################################################

// --- i8 ---
impl<'a> Div<&'a CausalTensor<i8>> for i8
where
    i8: Div<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;

    fn div(self, rhs: &'a CausalTensor<i8>) -> Self::Output {
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

impl Div<CausalTensor<i8>> for i8
where
    i8: Div<i8, Output = i8> + Clone,
{
    type Output = CausalTensor<i8>;
    fn div(self, rhs: CausalTensor<i8>) -> Self::Output {
        self.div(&rhs)
    }
}
