/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! HKT4 witness and RiemannMap implementation for CurvatureTensor.
//!
//! This module provides the `CurvatureTensorWitness` type that enables `CurvatureTensor`
//! to participate in HKT4 abstractions, along with the `RiemannMap` trait implementation.
//!
//! # ⚠️ Unsafe Dispatch Warning
//!
//! The `RiemannMap` trait is generic over its input types `A, B, C, D`. However,
//! the implementation requires concrete `TensorVector` types for the actual tensor
//! contraction operations.
//!
//! Since Rust's current GAT (Generic Associated Types) implementation cannot express
//! constraints like "A must be TensorVector" on HKT trait methods without modifying
//! the core abstraction, this implementation uses **unsafe pointer casting**.
//!
//! ## Safety Contract
//!
//! **SAFETY:** The caller MUST ensure that `A`, `B`, `C`, and `D` are `TensorVector`.
//! Passing any other type will result in **Undefined Behavior**.
//!
//! ## Recommendations
//!
//! 1. **Prefer safe alternatives**: Use `CurvatureTensor::contract()` directly when
//!    working with concrete `&[f64]` slices instead of the HKT `curvature()` method.
//!
//! 2. **Type-safe wrappers**: Consider using `TensorVector` explicitly in your code:
//!    ```ignore
//!    use deep_causality_topology::{CurvatureTensorWitness, TensorVector};
//!    use deep_causality_haft::RiemannMap;
//!    
//!    let u = TensorVector::new(&[1.0, 0.0, 0.0, 0.0]);
//!    let v = TensorVector::new(&[0.0, 1.0, 0.0, 0.0]);
//!    let w = TensorVector::new(&[0.0, 0.0, 1.0, 0.0]);
//!    
//!    // This is safe because we're using TensorVector
//!    let result: TensorVector = CurvatureTensorWitness::curvature(tensor, u, v, w);
//!    ```
//!
//! 3. **Future resolution**: This limitation may be resolved with Rust's new trait
//!    solver (`-Ztrait-solver=next`), which enables more expressive GAT constraints.
use crate::CurvatureTensor;
use deep_causality_algebra::Field;
use deep_causality_haft::{HKT4Unbound, NoConstraint, RiemannMap, Satisfies};
use deep_causality_num::Float;
// use deep_causality_tensor::CausalTensor; // Removed unused
use std::marker::PhantomData;

// ============================================================================
// HKT4 Witness
// ============================================================================

/// HKT4 witness for `CurvatureTensor<A, B, C, D>`.
#[derive(Debug, Clone, Copy, Default)]
pub struct CurvatureTensorWitness<T>(PhantomData<T>);

impl<T> HKT4Unbound for CurvatureTensorWitness<T>
where
    T: Satisfies<NoConstraint>,
{
    // We use NoConstraint because we are using unsafe dispatch and don't rely on Any.
    type Constraint = NoConstraint;
    type Type<A, B, C, D>
        = CurvatureTensor<T, A, B, C, D>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        C: Satisfies<NoConstraint>,
        D: Satisfies<NoConstraint>;
}

// ============================================================================
// TensorVector - Concrete Vector Type
// ============================================================================

/// A concrete vector type for curvature and scattering operations.
#[derive(Debug, Clone, PartialEq)]
pub struct TensorVector<T> {
    /// Vector components.
    pub data: Vec<T>,
}

impl<T> TensorVector<T>
where
    T: Field + Copy,
{
    /// Creates a new tensor vector from a slice.
    #[inline]
    pub fn new(data: &[T]) -> Self {
        Self {
            data: data.to_vec(),
        }
    }

    /// Creates a zero vector of given dimension.
    #[inline]
    pub fn zeros(dim: usize) -> Self {
        Self {
            data: vec![T::zero(); dim],
        }
    }

    /// Creates a basis vector e_i.
    #[inline]
    pub fn basis(dim: usize, i: usize) -> Self {
        let mut data = vec![T::zero(); dim];
        if i < dim {
            data[i] = T::one();
        }
        Self { data }
    }

    /// Returns the dimension.
    #[inline]
    pub fn dim(&self) -> usize {
        self.data.len()
    }

    /// Returns a slice of the data.
    #[inline]
    pub fn as_slice(&self) -> &[T] {
        &self.data
    }
}

impl<T> From<Vec<T>> for TensorVector<T> {
    fn from(data: Vec<T>) -> Self {
        Self { data }
    }
}

impl<T> From<TensorVector<T>> for Vec<T> {
    fn from(v: TensorVector<T>) -> Self {
        v.data
    }
}

// ============================================================================
// RiemannMap Trait Implementation (Unsafe Dispatch)
// ============================================================================

impl<T> RiemannMap<CurvatureTensorWitness<T>> for CurvatureTensorWitness<T>
where
    T: Field + Float + Clone + From<f64> + Into<f64> + Satisfies<NoConstraint> + Copy + PartialOrd,
{
    /// Computes curvature contraction R(u,v)w.
    ///
    /// # Safety — ACKNOWLEDGED GAT Limitation
    ///
    /// This generic method uses **unsafe pointer casting** to work around Rust's
    /// current GAT (Generic Associated Types) limitations that prevent proper
    /// type enforcement at the trait level.
    ///
    /// **Status:** ACKNOWLEDGED. This will be resolved when the new trait solver
    /// (`-Ztrait-solver=next`) stabilizes, enabling proper static type checks.
    /// See `deep_causality_tensor` HKT implementation for the same pattern.
    ///
    /// **SAFETY CONTRACT:** The caller **MUST** ensure A, B, C are `TensorVector`.
    fn curvature<A, B, C, D>(tensor: CurvatureTensor<T, A, B, C, D>, u: A, v: B, w: C) -> D
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        C: Satisfies<NoConstraint>,
        D: Satisfies<NoConstraint>,
    {
        // SAFETY: We assume the caller respects the implicit contract that A, B, C are TensorVector.
        // We cast the references to &TensorVector to invoke the underlying logic.
        // Since we take arguments by value, we must be careful.
        // TensorVector is a wrapper around Vec<f64>. If A is TensorVector, memory layout is identical.
        //
        // NOTE: This avoids the Any/downcast overhead and static lifetime requirement.
        unsafe {
            let u_ptr = &u as *const A as *const TensorVector<T>;
            let v_ptr = &v as *const B as *const TensorVector<T>;
            let w_ptr = &w as *const C as *const TensorVector<T>;

            // Dispatch to safe implementation
            let result = Self::geodesic_deviation_impl(&tensor, &*u_ptr, &*v_ptr, &*w_ptr);

            // Transmute result to D
            let result_ptr = &result as *const TensorVector<T> as *const D;
            // We read the D out of the result. Since result is a local variable,
            // we must ensure it isn't dropped twice. reading moves it out.
            let ret = std::ptr::read(result_ptr);
            std::mem::forget(result);
            ret
        }
    }

    /// Computes S-matrix scattering: (A, B) → (C, D).
    ///
    /// # Safety
    ///
    /// This method **unsafely casts** inputs to `TensorVector`.
    fn scatter<A, B, C, D>(interaction: CurvatureTensor<T, A, B, C, D>, in_1: A, in_2: B) -> (C, D)
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        C: Satisfies<NoConstraint>,
        D: Satisfies<NoConstraint>,
    {
        unsafe {
            let in1_ptr = &in_1 as *const A as *const TensorVector<T>;
            let in2_ptr = &in_2 as *const B as *const TensorVector<T>;

            let (out1, out2) = Self::scatter_impl(&interaction, &*in1_ptr, &*in2_ptr);

            // Transmute tuple (TensorVector, TensorVector) to (C, D).
            // Layout of (C, D) might differ from (TensorVector, TensorVector) if C!=D?
            let out1_ptr = &out1 as *const TensorVector<T> as *const C;
            let out2_ptr = &out2 as *const TensorVector<T> as *const D;

            let c = std::ptr::read(out1_ptr);
            let d = std::ptr::read(out2_ptr);

            // Ensure out1, out2 are not dropped since we moved their contents
            std::mem::forget(out1);
            std::mem::forget(out2);

            (c, d)
        }
    }
}

// ============================================================================
// Private safe implementations.
// ============================================================================

impl<T> CurvatureTensorWitness<T>
where
    T: Field + Float + Clone + From<f64> + Into<f64> + Copy + PartialOrd,
{
    /// Internal implementation of geodesic deviation.
    fn geodesic_deviation_impl<A, B, C, D>(
        tensor: &CurvatureTensor<T, A, B, C, D>,
        u: &TensorVector<T>,
        v: &TensorVector<T>,
        w: &TensorVector<T>,
    ) -> TensorVector<T> {
        let result = tensor.contract(u.as_slice(), v.as_slice(), w.as_slice());
        TensorVector::from(result)
    }

    /// Internal implementation of scattering.
    fn scatter_impl<A, B, C, D>(
        tensor: &CurvatureTensor<T, A, B, C, D>,
        in_1: &TensorVector<T>,
        in_2: &TensorVector<T>,
    ) -> (TensorVector<T>, TensorVector<T>) {
        let dim = tensor.dim();
        let mut out_1 = vec![T::zero(); dim];
        let mut out_2 = vec![T::zero(); dim];
        let point_five: T = <T as From<f64>>::from(0.5);

        for (c, out1_val) in out_1.iter_mut().enumerate() {
            for (d, out2_val) in out_2.iter_mut().enumerate() {
                let mut amplitude = T::zero();
                for a in 0..dim {
                    for b in 0..dim {
                        // tensor.get() returns T
                        let val = tensor.get(c, a, b, d);
                        amplitude += val * in_1.data[a] * in_2.data[b];
                    }
                }
                *out1_val += amplitude * point_five;
                *out2_val += amplitude * point_five;
            }
        }

        (TensorVector::from(out_1), TensorVector::from(out_2))
    }
}
