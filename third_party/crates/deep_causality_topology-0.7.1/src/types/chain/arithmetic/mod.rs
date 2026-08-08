/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::chain::Chain;
use core::ops::{Add, Mul, Neg, Sub};
use deep_causality_algebra::{AbelianGroup, Module, Ring};

// ============================================================================
// Add
// ============================================================================

impl<T> Add for Chain<T>
where
    T: AbelianGroup + Copy + PartialEq + Default + Neg<Output = T>,
{
    type Output = Self;

    fn add(self, rhs: Self) -> Self {
        Chain::add(&self, &rhs)
    }
}

impl<T> Add for &Chain<T>
where
    T: AbelianGroup + Copy + PartialEq + Default + Neg<Output = T>,
{
    type Output = Chain<T>;

    fn add(self, rhs: Self) -> Chain<T> {
        Chain::add(self, rhs)
    }
}

// ============================================================================
// Sub
// ============================================================================

impl<T> Sub for Chain<T>
where
    T: AbelianGroup + Copy + PartialEq + Default + Neg<Output = T>,
{
    type Output = Self;

    fn sub(self, rhs: Self) -> Self {
        Chain::sub(&self, &rhs)
    }
}

impl<T> Sub for &Chain<T>
where
    T: AbelianGroup + Copy + PartialEq + Default + Neg<Output = T>,
{
    type Output = Chain<T>;

    fn sub(self, rhs: Self) -> Chain<T> {
        Chain::sub(self, rhs)
    }
}

// ============================================================================
// Neg
// ============================================================================

impl<T> Neg for Chain<T>
where
    T: AbelianGroup + Copy + PartialEq + Default + Neg<Output = T>,
{
    type Output = Self;

    fn neg(self) -> Self {
        Chain::neg(&self)
    }
}

impl<T> Neg for &Chain<T>
where
    T: AbelianGroup + Copy + PartialEq + Default + Neg<Output = T>,
{
    type Output = Chain<T>;

    fn neg(self) -> Chain<T> {
        Chain::neg(self)
    }
}

// ============================================================================
// Mul (Scalar)
// ============================================================================

impl<T, S> Mul<S> for Chain<T>
where
    T: Module<S> + Copy,
    S: Ring + Copy,
{
    type Output = Self;

    fn mul(self, scalar: S) -> Self {
        self.scale(scalar)
    }
}

impl<T, S> Mul<S> for &Chain<T>
where
    T: Module<S> + Copy,
    S: Ring + Copy,
{
    type Output = Chain<T>;

    fn mul(self, scalar: S) -> Chain<T> {
        self.scale(scalar)
    }
}
