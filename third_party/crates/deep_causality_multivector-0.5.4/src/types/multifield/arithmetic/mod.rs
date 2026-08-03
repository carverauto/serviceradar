/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Arithmetic operators for CausalMultiField.

use super::CausalMultiField;
use crate::types::multifield::ops::batched_matmul::BatchedMatMul;
use deep_causality_algebra::{Field, Ring};
use deep_causality_num::Zero;
use deep_causality_tensor::CausalTensor;
use std::ops::{Add, Mul, Neg, Sub};

// === Zero Implementation ===

impl<T> Zero for CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd + Zero + Neg<Output = T>,
{
    fn zero() -> Self {
        panic!(
            "CausalMultiField::zero() requires shape and metric (context). Use zeros() factory method instead."
        )
    }

    fn is_zero(&self) -> bool {
        // Download and check all coefficients
        let mvs = self.to_coefficients();
        mvs.iter().all(|mv| mv.data.iter().all(|c| c.is_zero()))
    }
}

// === Add Implementation ===

impl<T> Add for CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let result = &self.data + &rhs.data;

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

impl<T> Add for &CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    type Output = CausalMultiField<T>;

    fn add(self, rhs: Self) -> Self::Output {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let result = &self.data + &rhs.data;

        CausalMultiField {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

// === Sub Implementation ===

impl<T> Sub for CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    type Output = Self;

    fn sub(self, rhs: Self) -> Self::Output {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let result = &self.data - &rhs.data;

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

impl<T> Sub for &CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    type Output = CausalMultiField<T>;

    fn sub(self, rhs: Self) -> Self::Output {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let result = &self.data - &rhs.data;

        CausalMultiField {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

// === Neg Implementation ===

impl<T> Neg for CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd + Neg<Output = T>,
{
    type Output = Self;

    fn neg(self) -> Self::Output {
        let neg_one = -T::one();
        let neg_tensor = CausalTensor::<T>::from_shape_fn(&[1], |_| neg_one);
        let result = &self.data * &neg_tensor;

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

// === Mul Implementation (Geometric Product) ===

impl<T> Mul for CausalMultiField<T>
where
    T: Field + Ring + Copy + Default + PartialOrd,
    CausalTensor<T>: BatchedMatMul<T>,
{
    type Output = Self;

    fn mul(self, rhs: Self) -> Self::Output {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let result = self.data.batched_matmul(&rhs.data);

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

impl<T> Mul for &CausalMultiField<T>
where
    T: Field + Ring + Copy + Default + PartialOrd,
    CausalTensor<T>: BatchedMatMul<T>,
{
    type Output = CausalMultiField<T>;

    fn mul(self, rhs: Self) -> Self::Output {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let result = self.data.batched_matmul(&rhs.data);

        CausalMultiField {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

impl<T> Mul<&CausalMultiField<T>> for CausalMultiField<T>
where
    T: Field + Ring + Copy + Default + PartialOrd,
    CausalTensor<T>: BatchedMatMul<T>,
{
    type Output = CausalMultiField<T>;

    fn mul(self, rhs: &CausalMultiField<T>) -> Self::Output {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let result = self.data.batched_matmul(&rhs.data);

        CausalMultiField {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}
