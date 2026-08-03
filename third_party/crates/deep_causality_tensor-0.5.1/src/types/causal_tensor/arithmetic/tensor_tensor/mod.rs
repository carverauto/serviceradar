/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalTensorError;
use crate::types::causal_tensor::CausalTensor;
use deep_causality_num::Zero;
use std::ops::{Add, Div, Mul, Sub};

//
// Implement Add trait for CausalTensor
//
impl<T> Add for &CausalTensor<T>
where
    T: Clone + PartialOrd + Add<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn add(self, rhs: &CausalTensor<T>) -> Self::Output {
        self.broadcast_op(rhs, |a, b| Ok(a + b))
            .expect("Broadcast failed in Add")
    }
}

// T + &T
impl<T> Add<&CausalTensor<T>> for CausalTensor<T>
where
    T: Clone + PartialOrd + Add<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn add(self, rhs: &CausalTensor<T>) -> Self::Output {
        (&self).add(rhs)
    }
}

// &T + T
impl<T> Add<CausalTensor<T>> for &CausalTensor<T>
where
    T: Clone + PartialOrd + Add<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn add(self, rhs: CausalTensor<T>) -> Self::Output {
        self.add(&rhs)
    }
}

impl<T> Add for CausalTensor<T>
where
    T: Clone + PartialOrd + Add<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn add(self, rhs: CausalTensor<T>) -> Self::Output {
        (&self).add(&rhs)
    }
}

//
// Implement Sub trait for CausalTensor
//
impl<T> Sub for &CausalTensor<T>
where
    T: Clone + PartialOrd + Sub<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn sub(self, rhs: &CausalTensor<T>) -> Self::Output {
        self.broadcast_op(rhs, |a, b| Ok(a - b))
            .expect("Broadcast failed in Sub")
    }
}

// T + &T
impl<T> Sub<&CausalTensor<T>> for CausalTensor<T>
where
    T: Clone + PartialOrd + Sub<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn sub(self, rhs: &CausalTensor<T>) -> Self::Output {
        (&self).sub(rhs)
    }
}

// &T + T
impl<T> Sub<CausalTensor<T>> for &CausalTensor<T>
where
    T: Clone + PartialOrd + Sub<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn sub(self, rhs: CausalTensor<T>) -> Self::Output {
        self.sub(&rhs)
    }
}

impl<T> Sub for CausalTensor<T>
where
    T: Clone + PartialOrd + Sub<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn sub(self, rhs: CausalTensor<T>) -> Self::Output {
        (&self).sub(&rhs)
    }
}

//
// Implement Mul trait for CausalTensor
//
impl<T> Mul for &CausalTensor<T>
where
    T: Clone + PartialOrd + Mul<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn mul(self, rhs: &CausalTensor<T>) -> Self::Output {
        self.broadcast_op(rhs, |a, b| Ok(a * b))
            .expect("Broadcast failed in Mul")
    }
}

// T + &T
impl<T> Mul<&CausalTensor<T>> for CausalTensor<T>
where
    T: Clone + PartialOrd + Mul<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn mul(self, rhs: &CausalTensor<T>) -> Self::Output {
        (&self).mul(rhs)
    }
}

// &T + T
impl<T> Mul<CausalTensor<T>> for &CausalTensor<T>
where
    T: Clone + PartialOrd + Mul<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn mul(self, rhs: CausalTensor<T>) -> Self::Output {
        self.mul(&rhs)
    }
}

impl<T> Mul for CausalTensor<T>
where
    T: Clone + PartialOrd + Mul<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn mul(self, rhs: CausalTensor<T>) -> Self::Output {
        (&self).mul(&rhs)
    }
}

//
// Implement Div trait for CausalTensor
//
impl<T> Div for &CausalTensor<T>
where
    T: Clone + PartialOrd + Zero + Div<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn div(self, rhs: &CausalTensor<T>) -> Self::Output {
        self.broadcast_op(rhs, |a, b| {
            if b == T::zero() {
                Err(CausalTensorError::InvalidOperation)
            } else {
                Ok(a / b)
            }
        })
        .expect("Broadcast failed or division by zero in Div")
    }
}

// T + &T
impl<T> Div<&CausalTensor<T>> for CausalTensor<T>
where
    T: Clone + PartialOrd + Zero + Div<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn div(self, rhs: &CausalTensor<T>) -> Self::Output {
        (&self).div(rhs)
    }
}

// &T + T
impl<T> Div<CausalTensor<T>> for &CausalTensor<T>
where
    T: Clone + PartialOrd + Zero + Div<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn div(self, rhs: CausalTensor<T>) -> Self::Output {
        self.div(&rhs)
    }
}

impl<T> Div for CausalTensor<T>
where
    T: Clone + PartialOrd + Zero + Div<T, Output = T>,
{
    type Output = CausalTensor<T>;

    fn div(self, rhs: CausalTensor<T>) -> Self::Output {
        (&self).div(&rhs)
    }
}
