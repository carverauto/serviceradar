/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Algebraic structure for [`CausalTensorTrain`]: value-level `+`, `-`, `*` operators and the
//! `deep_causality_num` tower (`Zero`/`One` → `AddGroup`/`AbelianGroup` → `Module`/`Ring`).
//!
//! The additive `0` and multiplicative (Hadamard) `1` are **shape-polymorphic identities**
//! ([`Identity`]): order-0 trains that the operators absorb as the neutral element against a train
//! of any shape — the tensor-train analogue of `CausalTensor`'s broadcasting scalar zero. They make
//! the laws `a + 0 = a` and `a * 1 = a` hold universally without a per-shape identity. The binary
//! operators delegate the ordinary (non-identity) case to the tested [`TensorTrain`] trait methods
//! and panic on a physical-dimension mismatch, matching `CausalTensor`'s arithmetic.

use crate::TensorTrain;
use crate::types::causal_tensor_network::causal_tensor_train::{CausalTensorTrain, Identity};
use core::ops::{Add, Mul, MulAssign, Neg, Sub};
use deep_causality_algebra::{
    AbelianGroup, Associative, Commutative, ConjugateScalar, Distributive, Scalar,
};
use deep_causality_num::{One, Zero};

// ============================================================================
// Additive group: Add, Sub, Neg
// ============================================================================

impl<T> Add for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    type Output = Self;

    fn add(self, rhs: Self) -> Self {
        match (self.identity_kind(), rhs.identity_kind()) {
            (Identity::AdditiveZero, _) => rhs,
            (_, Identity::AdditiveZero) => self,
            _ => TensorTrain::add(&self, &rhs)
                .expect("tensor-train add: physical dimensions must match"),
        }
    }
}

impl<T> Sub for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    type Output = Self;

    fn sub(self, rhs: Self) -> Self {
        match (self.identity_kind(), rhs.identity_kind()) {
            (_, Identity::AdditiveZero) => self,
            (Identity::AdditiveZero, _) => -rhs,
            _ => {
                let neg_rhs = rhs.scale(-T::one());
                TensorTrain::add(&self, &neg_rhs)
                    .expect("tensor-train sub: physical dimensions must match")
            }
        }
    }
}

impl<T> Neg for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    type Output = Self;

    fn neg(self) -> Self {
        match self.identity_kind() {
            // -0 = 0; negating the bare multiplicative identity is degenerate (left unchanged).
            Identity::AdditiveZero | Identity::MultiplicativeOne => self,
            Identity::Normal => self.scale(-T::one()),
        }
    }
}

// ============================================================================
// Scalar multiplication (the Module action): Mul<T>, MulAssign<T>
// ============================================================================

impl<T> Mul<T> for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    type Output = Self;

    fn mul(self, rhs: T) -> Self {
        match self.identity_kind() {
            // 0·s = 0; the bare multiplicative identity is left unchanged (degenerate, unused).
            Identity::AdditiveZero | Identity::MultiplicativeOne => self,
            Identity::Normal => self.scale(rhs),
        }
    }
}

impl<T> MulAssign<T> for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    fn mul_assign(&mut self, rhs: T) {
        if self.identity_kind() == Identity::Normal {
            *self = self.scale(rhs);
        }
    }
}

// ============================================================================
// Multiplicative monoid (Hadamard): Mul<Self>
// ============================================================================

impl<T> Mul for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    type Output = Self;

    fn mul(self, rhs: Self) -> Self {
        match (self.identity_kind(), rhs.identity_kind()) {
            (Identity::MultiplicativeOne, _) => rhs,
            (_, Identity::MultiplicativeOne) => self,
            // 0 · a = 0 under the Hadamard product too.
            (Identity::AdditiveZero, _) => self,
            (_, Identity::AdditiveZero) => rhs,
            _ => TensorTrain::hadamard(&self, &rhs)
                .expect("tensor-train hadamard: physical dimensions must match"),
        }
    }
}

// ============================================================================
// Identities
// ============================================================================

impl<T> Zero for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    fn zero() -> Self {
        Self::identity_train(Identity::AdditiveZero)
    }

    fn is_zero(&self) -> bool {
        match self.identity_kind() {
            Identity::AdditiveZero => true,
            Identity::MultiplicativeOne => false,
            // An ordinary train is zero iff all its core entries vanish (a sufficient, canonical
            // check; a non-canonical cancelling representation reports false).
            Identity::Normal => self
                .cores()
                .iter()
                .all(|c| c.as_slice().iter().all(|x| *x == T::zero())),
        }
    }
}

impl<T> One for CausalTensorTrain<T>
where
    T: Scalar + ConjugateScalar<Real = T>,
{
    fn one() -> Self {
        Self::identity_train(Identity::MultiplicativeOne)
    }

    fn is_one(&self) -> bool {
        // Only the canonical multiplicative identity is recognized; detecting an all-ones ordinary
        // train would require densification, so ordinary trains report false.
        self.identity_kind() == Identity::MultiplicativeOne
    }
}

// ============================================================================
// Marker traits → AddGroup / AbelianGroup / Ring / Module derive by blanket impl
// ============================================================================

impl<T> Associative for CausalTensorTrain<T> where T: Scalar + ConjugateScalar<Real = T> {}
impl<T> Commutative for CausalTensorTrain<T> where T: Scalar + ConjugateScalar<Real = T> {}
impl<T> Distributive for CausalTensorTrain<T> where T: Scalar + ConjugateScalar<Real = T> {}
impl<T> AbelianGroup for CausalTensorTrain<T> where T: Scalar + ConjugateScalar<Real = T> {}
