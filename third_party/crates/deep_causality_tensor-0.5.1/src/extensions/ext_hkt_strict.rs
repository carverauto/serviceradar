/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use deep_causality_haft::{Foldable, Functor, HKT, Pure, Satisfies};
use deep_causality_num_complex::Complex;

//  **Strict GAT HKTs are Solved in the Next-Generation Trait Solver**
//
// As of **January 2026**, we have confirmed that the inability to implement strict `Monad` and `CoMonad`
// (due to `E0276`/ `E0277` GAT normalization errors) is a **temporary limitation** of the current stable Rust trait solver.
//
// **Verification:**
// Using the nightly compiler with the new trait solver flag (`-Znext-solver`), the strict implementations
// for `StrictCausalTensorWitness` **compile successfully without modification**.
//

/// `TensorConstraint` enforces strict algebraic bounds on the types allowed within a CausalTensor HKT.
///
/// This corresponds to **Tier 4: TensorDataConstraint** in the spec.
/// It limits usage to types that are mathematically valid for tensor physics (Fields, Rings).
///
/// **Note:** This witness implements `Pure`, `Functor`, `Monad` and `CoMonad`.
/// It does NOT implement `Applicative` because `Applicative::apply` requires closures to be wrapped in the tensor,
/// but `TensorConstraint` strictly forbids closures. However, under the new `Monad: Functor + Pure` hierarchy,
/// we can still implement `Monad` without `Applicative`.
pub struct TensorConstraint;

// ============================================================================
// Allowed Physics Types (Whitelist)
// ============================================================================

impl Satisfies<TensorConstraint> for f32 {}
impl Satisfies<TensorConstraint> for f64 {}
impl Satisfies<TensorConstraint> for Complex<f32> {}
impl Satisfies<TensorConstraint> for Complex<f64> {}

impl Satisfies<TensorConstraint> for i8 {}
impl Satisfies<TensorConstraint> for i16 {}
impl Satisfies<TensorConstraint> for i32 {}
impl Satisfies<TensorConstraint> for i64 {}
impl Satisfies<TensorConstraint> for i128 {}

impl Satisfies<TensorConstraint> for u8 {}
impl Satisfies<TensorConstraint> for u16 {}
impl Satisfies<TensorConstraint> for u32 {}
impl Satisfies<TensorConstraint> for u64 {}
impl Satisfies<TensorConstraint> for u128 {}

impl Satisfies<TensorConstraint> for usize {}
impl Satisfies<TensorConstraint> for isize {}

// Allow nested tensors (Recursive structures)
impl<T> Satisfies<TensorConstraint> for CausalTensor<T> {}

// ============================================================================
// Strict HKT Witness
// ============================================================================

// StrictWitness implementations are currently blocked on stable
// because of Monad / Comonad issue. See note at the bottom of the file.
#[allow(dead_code)]
pub struct StrictCausalTensorWitness;

impl HKT for StrictCausalTensorWitness {
    type Constraint = TensorConstraint;
    type Type<T>
        = CausalTensor<T>
    where
        T: Satisfies<TensorConstraint>;
}

// ============================================================================
// HKT Traits Implementation
// ============================================================================

impl Functor<StrictCausalTensorWitness> for StrictCausalTensorWitness {
    fn fmap<A, B, Func>(m_a: CausalTensor<A>, f: Func) -> CausalTensor<B>
    where
        A: Satisfies<TensorConstraint>,
        B: Satisfies<TensorConstraint>,
        Func: FnMut(A) -> B,
    {
        // Functor fmap: transform each element directly
        let len = m_a.len();
        let data = m_a.into_vec().into_iter().map(f).collect::<Vec<B>>();
        CausalTensor::from_vec(data, &[len])
    }
}

impl Foldable<StrictCausalTensorWitness> for StrictCausalTensorWitness {
    fn fold<A, B, Func>(fa: CausalTensor<A>, init: B, f: Func) -> B
    where
        A: Satisfies<TensorConstraint>,
        Func: FnMut(B, A) -> B,
    {
        fa.into_vec().into_iter().fold(init, f)
    }
}

impl Pure<StrictCausalTensorWitness> for StrictCausalTensorWitness {
    fn pure<T>(value: T) -> CausalTensor<T>
    where
        T: Satisfies<TensorConstraint>,
    {
        // 1D tensor with single element (List Monad semantics)
        CausalTensor::from_vec(vec![value], &[1])
    }
}

// Monad and CoMonad implementations are currently blocked on stable
// by multiple rustc GAT normalization issue (E0276/E0277) in the trait solver.
//
// STATUS: Verified working on nightly with `-Znext-solver`.
//
// Uncomment when new trait solver beomces GA / Stable.
//
// impl Monad<StrictCausalTensorWitness> for StrictCausalTensorWitness {
//     fn bind<A, B, Func>(m_a: CausalTensor<A>, mut f: Func) -> CausalTensor<B>
//     where
//         A: Satisfies<TensorConstraint>,
//         B: Satisfies<TensorConstraint>,
//         Func: FnMut(A) -> CausalTensor<B>,
//     {
//         // Monadic bind for List/Tensor: apply f to each element and flatten the result
//         let mut result_data = Vec::with_capacity(m_a.len());
//         for a in m_a.into_vec() {
//             let mb = f(a);
//             result_data.extend(mb.into_vec());
//         }
//         let len = result_data.len();
//         CausalTensor::from_vec(result_data, &[len])
//     }
// }
//
// impl CoMonad<StrictCausalTensorWitness> for StrictCausalTensorWitness {
//     fn extract<A>(fa: &CausalTensor<A>) -> A
//     where
//         A: Satisfies<TensorConstraint> + Clone,
//     {
//         fa.as_slice()
//             .first()
//             .cloned()
//             .expect("CoMonad::extract cannot be called on an empty CausalTensor.")
//     }
//
//     fn extend<A, B, Func>(fa: &CausalTensor<A>, mut f: Func) -> CausalTensor<B>
//     where
//         Func: FnMut(&CausalTensor<A>) -> B,
//         A: Satisfies<TensorConstraint> + Clone,
//         B: Satisfies<TensorConstraint>,
//     {
//         let len = fa.len();
//         let shape = fa.shape().to_vec();
//         let new_data: Vec<B> = (0..len)
//             .map(|i| {
//                 let view = fa.shifted_view(i);
//                 f(&view)
//             })
//             .collect();
//         CausalTensor::from_vec(new_data, &shape)
//     }
// }
