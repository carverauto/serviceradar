/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use deep_causality_algebra::{AbelianGroup, Ring};
use std::ops::{Add, AddAssign, Mul, MulAssign, Neg, Sub, SubAssign};

// ============================================================================
// Add Implementations (4 variants for all ownership combinations)
// ============================================================================

// owned + owned
impl<T> Add for CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq, // Added Default + PartialEq
{
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        CsrMatrix::add(&self, &rhs)
    }
}

// ref + ref
impl<T> Add for &CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq, // Added Default + PartialEq
{
    type Output = CsrMatrix<T>;
    fn add(self, rhs: Self) -> CsrMatrix<T> {
        CsrMatrix::add(self, rhs)
    }
}

// owned + ref
impl<T> Add<&CsrMatrix<T>> for CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq, // Added Default + PartialEq
{
    type Output = Self;
    fn add(self, rhs: &Self) -> Self {
        CsrMatrix::add(&self, rhs)
    }
}

// ref + owned
impl<T> Add<CsrMatrix<T>> for &CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq, // Added Default + PartialEq
{
    type Output = CsrMatrix<T>;
    fn add(self, rhs: CsrMatrix<T>) -> CsrMatrix<T> {
        CsrMatrix::add(self, &rhs)
    }
}

// ============================================================================
// AddAssign Implementations
// ============================================================================

impl<T> AddAssign for CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq,
{
    fn add_assign(&mut self, rhs: Self) {
        *self = CsrMatrix::add(self, &rhs);
    }
}

impl<T> AddAssign<&CsrMatrix<T>> for CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq,
{
    fn add_assign(&mut self, rhs: &Self) {
        *self = CsrMatrix::add(self, rhs);
    }
}

// ============================================================================
// Sub Implementations (4 variants for all ownership combinations)
// ============================================================================

// owned + owned
impl<T> Sub for CsrMatrix<T>
where
    T: AbelianGroup
        + Copy
        + std::ops::Sub<Output = T>
        + std::ops::Neg<Output = T>
        + Default
        + PartialEq, // Added Default + PartialEq
{
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        CsrMatrix::sub(&self, &rhs)
    }
}

// ref + ref
impl<T> Sub for &CsrMatrix<T>
where
    T: AbelianGroup
        + Copy
        + std::ops::Sub<Output = T>
        + std::ops::Neg<Output = T>
        + Default
        + PartialEq, // Added Default + PartialEq
{
    type Output = CsrMatrix<T>;
    fn sub(self, rhs: Self) -> CsrMatrix<T> {
        CsrMatrix::sub(self, rhs)
    }
}

// owned + ref
impl<T> Sub<&CsrMatrix<T>> for CsrMatrix<T>
where
    T: AbelianGroup
        + Copy
        + std::ops::Sub<Output = T>
        + std::ops::Neg<Output = T>
        + Default
        + PartialEq, // Added Default + PartialEq
{
    type Output = Self;
    fn sub(self, rhs: &Self) -> Self {
        CsrMatrix::sub(&self, rhs)
    }
}

// ref + owned
impl<T> Sub<CsrMatrix<T>> for &CsrMatrix<T>
where
    T: AbelianGroup
        + Copy
        + std::ops::Sub<Output = T>
        + std::ops::Neg<Output = T>
        + Default
        + PartialEq, // Added Default + PartialEq
{
    type Output = CsrMatrix<T>;
    fn sub(self, rhs: CsrMatrix<T>) -> CsrMatrix<T> {
        CsrMatrix::sub(self, &rhs)
    }
}

// ============================================================================
// SubAssign Implementations
// ============================================================================

impl<T> SubAssign for CsrMatrix<T>
where
    T: AbelianGroup
        + Copy
        + std::ops::Sub<Output = T>
        + std::ops::Neg<Output = T>
        + Default
        + PartialEq,
{
    fn sub_assign(&mut self, rhs: Self) {
        *self = CsrMatrix::sub(self, &rhs);
    }
}

impl<T> SubAssign<&CsrMatrix<T>> for CsrMatrix<T>
where
    T: AbelianGroup
        + Copy
        + std::ops::Sub<Output = T>
        + std::ops::Neg<Output = T>
        + Default
        + PartialEq,
{
    fn sub_assign(&mut self, rhs: &Self) {
        *self = CsrMatrix::sub(self, rhs);
    }
}

// ============================================================================
// Neg Implementations (2 variants for owned and borrowed)
// ============================================================================

// owned
impl<T> Neg for CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq, // Added Default + PartialEq
{
    type Output = Self;
    fn neg(self) -> Self {
        CsrMatrix::neg(&self) // Calls the CsrMatrix::neg(&self) method
    }
}

// borrowed
impl<T> Neg for &CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq, // Added Default + PartialEq
{
    type Output = CsrMatrix<T>;
    fn neg(self) -> CsrMatrix<T> {
        CsrMatrix::neg(self) // Calls the CsrMatrix::neg(&self) method
    }
}

// ============================================================================
// Neg Implementations (2 variants for owned and borrowed)
// ============================================================================

// owned + owned
impl<T> Mul for CsrMatrix<T>
where
    T: Ring + Copy + Default + PartialEq + std::ops::AddAssign, // Added Default + PartialEq and AddAssign
{
    type Output = Self;
    fn mul(self, rhs: Self) -> Self {
        CsrMatrix::mul(&self, &rhs)
    }
}

// ref + ref
impl<T> Mul for &CsrMatrix<T>
where
    T: Ring + Copy + Default + PartialEq + std::ops::AddAssign, // Added Default + PartialEq and AddAssign
{
    type Output = CsrMatrix<T>;
    fn mul(self, rhs: Self) -> CsrMatrix<T> {
        CsrMatrix::mul(self, rhs)
    }
}

// owned + ref
impl<T> Mul<&CsrMatrix<T>> for CsrMatrix<T>
where
    T: Ring + Copy + Default + PartialEq + std::ops::AddAssign, // Added Default + PartialEq and AddAssign
{
    type Output = Self;
    fn mul(self, rhs: &Self) -> Self {
        CsrMatrix::mul(&self, rhs)
    }
}

// ref + owned
impl<T> Mul<CsrMatrix<T>> for &CsrMatrix<T>
where
    T: Ring + Copy + Default + PartialEq + std::ops::AddAssign, // Added Default + PartialEq and AddAssign
{
    type Output = CsrMatrix<T>;
    fn mul(self, rhs: CsrMatrix<T>) -> CsrMatrix<T> {
        CsrMatrix::mul(self, &rhs)
    }
}

// ============================================================================
// MulAssign Implementations
// ============================================================================

impl<T> MulAssign for CsrMatrix<T>
where
    T: Ring + Copy + Default + PartialEq + std::ops::AddAssign,
{
    fn mul_assign(&mut self, rhs: Self) {
        *self = CsrMatrix::mul(self, &rhs);
    }
}

impl<T> MulAssign<&CsrMatrix<T>> for CsrMatrix<T>
where
    T: Ring + Copy + Default + PartialEq + std::ops::AddAssign,
{
    fn mul_assign(&mut self, rhs: &Self) {
        *self = CsrMatrix::mul(self, rhs);
    }
}

// ============================================================================
// Scalar Mul Implementations (Module support)
// ============================================================================

// CsrMatrix<T> * S -> CsrMatrix<T>
impl<T, S> Mul<S> for CsrMatrix<T>
where
    T: Copy + Mul<S, Output = T>,
    S: Copy + Ring, // Ring bound usually implies Copy, but explicit is fine
{
    type Output = CsrMatrix<T>;

    fn mul(self, scalar: S) -> CsrMatrix<T> {
        let new_values: Vec<T> = self.values.iter().map(|&v| v * scalar).collect();
        CsrMatrix {
            row_indices: self.row_indices,
            col_indices: self.col_indices,
            values: new_values,
            shape: self.shape,
        }
    }
}

// &CsrMatrix<T> * S -> CsrMatrix<T>
impl<T, S> Mul<S> for &CsrMatrix<T>
where
    T: Copy + Mul<S, Output = T>,
    S: Copy + Ring,
{
    type Output = CsrMatrix<T>;

    fn mul(self, scalar: S) -> CsrMatrix<T> {
        let new_values: Vec<T> = self.values.iter().map(|&v| v * scalar).collect();
        CsrMatrix {
            row_indices: self.row_indices.clone(),
            col_indices: self.col_indices.clone(),
            values: new_values,
            shape: self.shape,
        }
    }
}

// CsrMatrix<T> *= S
impl<T, S> MulAssign<S> for CsrMatrix<T>
where
    T: Copy + MulAssign<S>,
    S: Copy + Ring,
{
    fn mul_assign(&mut self, scalar: S) {
        for val in &mut self.values {
            *val *= scalar;
        }
    }
}
