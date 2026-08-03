/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_tensor::CausalTensor;
use std::ops::{Add, Div, Mul, Sub};

// ############################################################################
// ############################### ADDITION ###################################
// ############################################################################

// --- f64 ---
// Implementation for `f64 + &CausalTensor<f64>`
impl<'a> Add<&'a CausalTensor<f64>> for f64
where
    f64: Add<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;

    fn add(self, rhs: &'a CausalTensor<f64>) -> Self::Output {
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

// Implementation for `f64 + CausalTensor<f64>` (consuming)
impl Add<CausalTensor<f64>> for f64
where
    f64: Add<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;
    fn add(self, rhs: CausalTensor<f64>) -> Self::Output {
        self.add(&rhs)
    }
}

// ############################################################################
// ############################## SUBTRACTION #################################
// ############################################################################

// --- f64 ---
impl<'a> Sub<&'a CausalTensor<f64>> for f64
where
    f64: Sub<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;

    fn sub(self, rhs: &'a CausalTensor<f64>) -> Self::Output {
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

impl Sub<CausalTensor<f64>> for f64
where
    f64: Sub<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;
    fn sub(self, rhs: CausalTensor<f64>) -> Self::Output {
        self.sub(&rhs)
    }
}

// ############################################################################
// ############################ MULTIPLICATION ################################
// ############################################################################

// --- f64 ---
impl<'a> Mul<&'a CausalTensor<f64>> for f64
where
    f64: Mul<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;

    fn mul(self, rhs: &'a CausalTensor<f64>) -> Self::Output {
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

impl Mul<CausalTensor<f64>> for f64
where
    f64: Mul<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;
    fn mul(self, rhs: CausalTensor<f64>) -> Self::Output {
        self.mul(&rhs)
    }
}

// ############################################################################
// ############################### DIVISION ###################################
// ############################################################################

// --- f64 ---
impl<'a> Div<&'a CausalTensor<f64>> for f64
where
    f64: Div<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;

    fn div(self, rhs: &'a CausalTensor<f64>) -> Self::Output {
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

impl Div<CausalTensor<f64>> for f64
where
    f64: Div<f64, Output = f64> + Clone,
{
    type Output = CausalTensor<f64>;
    fn div(self, rhs: CausalTensor<f64>) -> Self::Output {
        self.div(&rhs)
    }
}
