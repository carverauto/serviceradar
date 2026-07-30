/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! HKT (Higher-Kinded Types) implementation for CausalMultiField.
//!
//! # ⚠️ Unsafe Dispatch Warning
//!
//! This module uses **unsafe pointer casting** to work around Rust's current GAT
//! (Generic Associated Types) limitations that prevent proper type enforcement
//! at the trait level.
//!
//! **Status:** This is a temporary workaround until the new trait solver
//! (`-Ztrait-solver=next`) stabilizes in Rust stable, which will enable proper
//! static type constraints on HKT trait methods.
//!
//! ## Safety Contract
//!
//! **SAFETY:** The caller MUST ensure that `A` and `C` types match the concrete
//! type `T` used when constructing `CausalMultiFieldWitness<T>`.
//! Passing any other type will result in **Undefined Behavior**.
//!
//! ## Recommendations
//!
//! 1. **Prefer safe alternatives**: Use `CausalMultiField` methods directly
//!    (`scale`, `to_coefficients`, `from_coefficients`) when possible.
//!
//! 2. **Type-safe usage**: Always use matching types:
//!    ```ignore
//!    use deep_causality_multivector::{CausalMultiFieldWitness, CausalMultiField};
//!    use deep_causality_haft::Functor;
//!    
//!    let field: CausalMultiField<f64> = /* ... */;
//!    // Use CausalMultiFieldWitness<f64> for f64 fields
//!    let scaled: CausalMultiField<f64> = CausalMultiFieldWitness::<f64>::fmap(field, |x| x * 2.0);
//!    ```
//!
//! 3. **Future resolution**: This limitation will be resolved when the new trait
//!    solver stabilizes, enabling proper generic constraints.

use crate::CausalMultiField;
use deep_causality_algebra::Field;
use deep_causality_haft::{
    Applicative, CoMonad, Functor, HKT, Monad, NoConstraint, Pure, Satisfies,
};
use deep_causality_metric::Metric;
use deep_causality_tensor::CausalTensor;
use std::marker::PhantomData;

/// HKT witness for `CausalMultiField<T>`.
///
/// The type parameter `T` specifies the concrete coefficient type (e.g., `f64`, `f32`).
/// All HKT operations assume the generic type parameters match `T`.
#[derive(Debug, Clone, Copy, Default)]
pub struct CausalMultiFieldWitness<T>(PhantomData<T>);

impl<T> CausalMultiFieldWitness<T> {
    /// Creates a new witness.
    pub fn new() -> Self {
        Self(PhantomData)
    }
}

impl<T> HKT for CausalMultiFieldWitness<T>
where
    T: Satisfies<NoConstraint>,
{
    type Constraint = NoConstraint;
    type Type<A> = CausalMultiField<A>;
}

// ============================================================================
// Functor Implementation (Unsafe Dispatch)
// ============================================================================

impl<T> Functor<CausalMultiFieldWitness<T>> for CausalMultiFieldWitness<T>
where
    T: Field + Copy + Default + PartialOrd + Satisfies<NoConstraint>,
{
    /// Maps a function over the field coefficients.
    ///
    /// # Safety — ACKNOWLEDGED GAT Limitation
    ///
    /// This method uses **unsafe pointer casting** to work around Rust's
    /// current GAT limitations. This will be resolved when the new trait
    /// solver (`-Ztrait-solver=next`) stabilizes.
    ///
    /// **SAFETY CONTRACT:** The caller **MUST** ensure A and C are the same as T.
    fn fmap<A, C, Func>(fa: CausalMultiField<A>, mut f: Func) -> CausalMultiField<C>
    where
        A: Satisfies<NoConstraint>,
        C: Satisfies<NoConstraint>,
        Func: FnMut(A) -> C,
    {
        // SAFETY: We assume A and C are T. Memory layout is identical.
        unsafe {
            let fa_ptr = &fa as *const CausalMultiField<A> as *const CausalMultiField<T>;
            let fa_concrete = &*fa_ptr;

            // Extract data and apply function
            let data_vec = fa_concrete.data().as_slice();
            let transformed: Vec<T> = data_vec
                .iter()
                .map(|x| {
                    // Transmute T -> A, apply f, transmute result -> T
                    let a_val = std::mem::transmute_copy::<T, A>(x);
                    let c_val = f(a_val);
                    std::mem::transmute_copy::<C, T>(&c_val)
                })
                .collect();

            // Copy dx (same type T)
            let dx = *fa_concrete.dx();

            // Build result
            let new_tensor = CausalTensor::from_slice(&transformed, fa_concrete.data().shape());
            let result = CausalMultiField::<T> {
                data: new_tensor,
                metric: fa_concrete.metric(),
                dx,
                shape: *fa_concrete.shape(),
            };

            // Transmute to CausalMultiField<C>
            let result_ptr = &result as *const CausalMultiField<T> as *const CausalMultiField<C>;
            let ret = std::ptr::read(result_ptr);
            std::mem::forget(result);
            // std::mem::forget(fa); // Do not forget the input `fa`, let it drop naturally.
            ret
        }
    }
}

// ============================================================================
// Pure Implementation
// ============================================================================

impl<T> Pure<CausalMultiFieldWitness<T>> for CausalMultiFieldWitness<T>
where
    T: Field + Copy + Default + PartialOrd + Satisfies<NoConstraint>,
{
    /// Creates a field with all coefficients set to the given value.
    ///
    /// Note: Uses default metric (4D Lorentzian), shape `[1,1,1]`, and unit grid spacing.
    /// For specific configurations, use `CausalMultiField::zeros()` or other factory methods.
    fn pure<A>(value: A) -> CausalMultiField<A>
    where
        A: Satisfies<NoConstraint>,
    {
        // SAFETY: We assume A is T.
        unsafe {
            let val_ptr = &value as *const A as *const T;
            let val_t = *val_ptr;

            // Use 4D Lorentzian metric (1 timelike + 3 spacelike)
            let metric = Metric::from_signature(1, 3, 0);
            let shape = [1, 1, 1];
            let dx = [T::one(), T::one(), T::one()];

            let matrix_dim = 1 << (metric.dimension().div_ceil(2));
            let total_size = shape[0] * shape[1] * shape[2] * matrix_dim * matrix_dim;
            let data = vec![val_t; total_size];
            let tensor = CausalTensor::from_slice(
                &data,
                &[shape[0], shape[1], shape[2], matrix_dim, matrix_dim],
            );

            let result = CausalMultiField::<T> {
                data: tensor,
                metric,
                dx,
                shape,
            };

            let result_ptr = &result as *const CausalMultiField<T> as *const CausalMultiField<A>;
            let ret = std::ptr::read(result_ptr);
            std::mem::forget(result);
            // std::mem::forget(value); // This causes a memory leak.
            ret
        }
    }
}

// ============================================================================
// Applicative Implementation
// ============================================================================

impl<T> Applicative<CausalMultiFieldWitness<T>> for CausalMultiFieldWitness<T>
where
    T: Field + Copy + Default + PartialOrd + Satisfies<NoConstraint>,
{
    /// Applies a field of functions to a field of values.
    ///
    /// # Note
    ///
    /// This is not meaningful for CausalMultiField because we can't store
    /// functions in a tensor. Use `fmap` for function application.
    fn apply<A, C, Func>(
        _ff: CausalMultiField<Func>,
        _fa: CausalMultiField<A>,
    ) -> CausalMultiField<C>
    where
        A: Satisfies<NoConstraint> + Clone,
        C: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> C,
    {
        // Applicative for fields of functions is not meaningful for CausalMultiField
        // because we can't store functions in a tensor.
        panic!(
            "CausalMultiField::apply is not supported. \
             Use fmap for function application over field values."
        );
    }
}

// ============================================================================
// Monad Implementation (Unsafe Dispatch)
// ============================================================================

impl<T> Monad<CausalMultiFieldWitness<T>> for CausalMultiFieldWitness<T>
where
    T: Field + Copy + Default + PartialOrd + Satisfies<NoConstraint>,
{
    /// Monadic bind for CausalMultiField.
    ///
    /// Note: This extracts the first coefficient, applies f, and returns the result.
    /// For proper field composition, use matrix multiplication via `*` operator.
    fn bind<A, C, Func>(ma: CausalMultiField<A>, mut f: Func) -> CausalMultiField<C>
    where
        A: Satisfies<NoConstraint>,
        C: Satisfies<NoConstraint>,
        Func: FnMut(A) -> CausalMultiField<C>,
    {
        // SAFETY: We assume A and C are T.
        unsafe {
            let ma_ptr = &ma as *const CausalMultiField<A> as *const CausalMultiField<T>;
            let ma_concrete = &*ma_ptr;

            // Extract first coefficient and apply f
            let data_vec = ma_concrete.data().as_slice();
            if let Some(&first_val) = data_vec.first() {
                let a_val = std::mem::transmute_copy::<T, A>(&first_val);
                let result = f(a_val);
                // std::mem::forget(ma); // This causes a memory leak.
                return result;
            }

            // Empty field - return a zero field
            let metric = ma_concrete.metric();
            let shape = *ma_concrete.shape();
            let dx = *ma_concrete.dx();
            let matrix_dim = 1 << (metric.dimension().div_ceil(2));
            let total_size = shape[0] * shape[1] * shape[2] * matrix_dim * matrix_dim;
            let data = vec![T::zero(); total_size];
            let tensor = CausalTensor::from_slice(
                &data,
                &[shape[0], shape[1], shape[2], matrix_dim, matrix_dim],
            );

            let result = CausalMultiField::<T> {
                data: tensor,
                metric,
                dx,
                shape,
            };

            let result_ptr = &result as *const CausalMultiField<T> as *const CausalMultiField<C>;
            let ret = std::ptr::read(result_ptr);
            std::mem::forget(result);
            // std::mem::forget(ma); // This causes a memory leak.
            ret
        }
    }
}

// ============================================================================
// CoMonad Implementation (Unsafe Dispatch)
// ============================================================================

impl<T> CoMonad<CausalMultiFieldWitness<T>> for CausalMultiFieldWitness<T>
where
    T: Field + Copy + Default + PartialOrd + Satisfies<NoConstraint>,
{
    /// Extracts the "focus" value from the field.
    ///
    /// Returns the first coefficient (scalar part at origin).
    fn extract<A>(fa: &CausalMultiField<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        // SAFETY: We assume A is T.
        unsafe {
            let fa_ptr = fa as *const CausalMultiField<A> as *const CausalMultiField<T>;
            let fa_concrete = &*fa_ptr;

            let data_vec = fa_concrete.data().as_slice();
            let first_val = data_vec.first().copied().unwrap_or_else(T::zero);

            std::mem::transmute_copy::<T, A>(&first_val)
        }
    }

    /// Extends a local computation to the entire field.
    ///
    /// Applies the function to the field and broadcasts the result.
    fn extend<A, C, Func>(fa: &CausalMultiField<A>, mut f: Func) -> CausalMultiField<C>
    where
        A: Satisfies<NoConstraint> + Clone,
        C: Satisfies<NoConstraint>,
        Func: FnMut(&CausalMultiField<A>) -> C,
    {
        // For extend, we apply f to the entire field and use the result
        // as a constant field.
        unsafe {
            let c_val = f(fa);
            let c_t = std::mem::transmute_copy::<C, T>(&c_val);

            let fa_ptr = fa as *const CausalMultiField<A> as *const CausalMultiField<T>;
            let fa_concrete = &*fa_ptr;

            let metric = fa_concrete.metric();
            let shape = *fa_concrete.shape();
            let dx = *fa_concrete.dx();
            let matrix_dim = 1 << (metric.dimension().div_ceil(2));
            let total_size = shape[0] * shape[1] * shape[2] * matrix_dim * matrix_dim;
            let data = vec![c_t; total_size];
            let tensor = CausalTensor::from_slice(
                &data,
                &[shape[0], shape[1], shape[2], matrix_dim, matrix_dim],
            );

            let result = CausalMultiField::<T> {
                data: tensor,
                metric,
                dx,
                shape,
            };

            let result_ptr = &result as *const CausalMultiField<T> as *const CausalMultiField<C>;
            let ret = std::ptr::read(result_ptr);
            std::mem::forget(result);
            std::mem::forget(c_val);
            ret
        }
    }
}
