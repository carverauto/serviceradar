/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalMultiVector, MultiVector};
use core::ops::{Add, AddAssign, Div, Mul, MulAssign, Neg, Sub, SubAssign};
use deep_causality_algebra::Field;
use deep_causality_num::Zero;

/// Implements component-wise addition of multivectors.
/// $$ A + B = \sum_{I} (a_I + b_I) e_I $$
impl<T> Add for CausalMultiVector<T>
where
    T: Add<Output = T> + Copy + Clone + PartialEq,
{
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        if self.metric != rhs.metric {
            panic!(
                "Dimension mismatch in addition: {:?} vs {:?}",
                self.metric, rhs.metric
            );
        }
        let data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a + *b)
            .collect();

        Self {
            data,
            metric: self.metric,
        }
    }
}

// Support: Reference addition ( &A + &B )
// This allows x.as_inner() + z.as_inner() to work without manual cloning everywhere
impl<'b, T> Add<&'b CausalMultiVector<T>> for &CausalMultiVector<T>
where
    T: Copy + Add<Output = T> + Zero,
{
    type Output = CausalMultiVector<T>;

    fn add(self, rhs: &'b CausalMultiVector<T>) -> Self::Output {
        if self.metric != rhs.metric {
            panic!("Metric mismatch in addition");
        }
        // Zip and add
        let new_data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a + *b)
            .collect();

        CausalMultiVector {
            data: new_data,
            metric: self.metric,
        }
    }
}

/// Implements component-wise subtraction of multivectors.
/// $$ A - B = \sum_{I} (a_I - b_I) e_I $$
impl<T> Sub for CausalMultiVector<T>
where
    T: Sub<Output = T> + Copy + Clone + PartialEq,
{
    type Output = Self;

    fn sub(self, rhs: Self) -> Self::Output {
        if self.metric != rhs.metric {
            panic!(
                "Dimension mismatch in subtraction: {:?} vs {:?}",
                self.metric, rhs.metric
            );
        }
        let data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a - *b)
            .collect();

        Self {
            data,
            metric: self.metric,
        }
    }
}

// Support: Reference subtraction ( &A - &B )
impl<'b, T> Sub<&'b CausalMultiVector<T>> for &CausalMultiVector<T>
where
    T: Copy + Sub<Output = T> + Zero,
{
    type Output = CausalMultiVector<T>;

    fn sub(self, rhs: &'b CausalMultiVector<T>) -> Self::Output {
        if self.metric != rhs.metric {
            panic!("Metric mismatch in subtraction");
        }
        // Zip and subtract
        let new_data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a - *b)
            .collect();

        CausalMultiVector {
            data: new_data,
            metric: self.metric,
        }
    }
}

/// Implements scalar multiplication.
/// $$ A s = \sum_{I} (a_I s) e_I $$
impl<T> Mul<T> for CausalMultiVector<T>
where
    T: Mul<Output = T> + Copy + Clone,
{
    type Output = Self;

    fn mul(self, rhs: T) -> Self::Output {
        let data = self.data.iter().map(|a| *a * rhs).collect();
        Self {
            data,
            metric: self.metric,
        }
    }
}

// Support: Reference scalar multiplication ( &A * scalar )
impl<T> Mul<T> for &CausalMultiVector<T>
where
    T: Copy + Mul<Output = T>,
{
    type Output = CausalMultiVector<T>;

    fn mul(self, rhs: T) -> Self::Output {
        let data = self.data.iter().map(|a| *a * rhs).collect();
        CausalMultiVector {
            data,
            metric: self.metric,
        }
    }
}

/// Geometric product via `*` operator (CPU-only).
impl<T> Mul for CausalMultiVector<T>
where
    T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
{
    type Output = Self;

    fn mul(self, rhs: Self) -> Self::Output {
        self.geometric_product(&rhs)
    }
}

/// Reference geometric product `&A * &B` (CPU-only).
impl<'b, T> Mul<&'b CausalMultiVector<T>> for &CausalMultiVector<T>
where
    T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
{
    type Output = CausalMultiVector<T>;

    fn mul(self, rhs: &'b CausalMultiVector<T>) -> Self::Output {
        self.geometric_product(rhs)
    }
}

/// Implements scalar division.
/// $$ A / s = \sum_{I} (a_I / s) e_I $$
impl<T> Div<T> for CausalMultiVector<T>
where
    T: Div<Output = T> + Copy + Clone,
{
    type Output = Self;

    fn div(self, rhs: T) -> Self::Output {
        let data = self.data.iter().map(|a| *a / rhs).collect();
        Self {
            data,
            metric: self.metric,
        }
    }
}

// Support: Reference scalar division ( &A / scalar )
impl<T> Div<T> for &CausalMultiVector<T>
where
    T: Copy + Div<Output = T>,
{
    type Output = CausalMultiVector<T>;

    fn div(self, rhs: T) -> Self::Output {
        let data = self.data.iter().map(|a| *a / rhs).collect();
        CausalMultiVector {
            data,
            metric: self.metric,
        }
    }
}
// =============================================================================
// Assignment Operators
// =============================================================================

impl<T> AddAssign for CausalMultiVector<T>
where
    T: AddAssign + Copy + Clone + PartialEq,
{
    fn add_assign(&mut self, rhs: Self) {
        if self.metric != rhs.metric {
            panic!(
                "Dimension mismatch in addition: {:?} vs {:?}",
                self.metric, rhs.metric
            );
        }
        if self.data.len() != rhs.data.len() {
            panic!(
                "Data length mismatch in addition: {} vs {}",
                self.data.len(),
                rhs.data.len()
            );
        }
        for (a, b) in self.data.iter_mut().zip(rhs.data.iter()) {
            *a += *b;
        }
    }
}

impl<'a, T> AddAssign<&'a CausalMultiVector<T>> for CausalMultiVector<T>
where
    T: AddAssign + Copy + Clone + PartialEq,
{
    fn add_assign(&mut self, rhs: &'a CausalMultiVector<T>) {
        if self.metric != rhs.metric {
            panic!(
                "Dimension mismatch in addition: {:?} vs {:?}",
                self.metric, rhs.metric
            );
        }
        if self.data.len() != rhs.data.len() {
            panic!(
                "Data length mismatch in addition: {} vs {}",
                self.data.len(),
                rhs.data.len()
            );
        }
        for (a, b) in self.data.iter_mut().zip(rhs.data.iter()) {
            *a += *b;
        }
    }
}

impl<T> MulAssign<T> for CausalMultiVector<T>
where
    T: MulAssign + Copy + Clone,
{
    fn mul_assign(&mut self, rhs: T) {
        for a in self.data.iter_mut() {
            *a *= rhs;
        }
    }
}
