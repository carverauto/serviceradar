/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use crate::traits::tensor::Tensor;
use deep_causality_haft::{
    Applicative, CoMonad, Foldable, Functor, HKT, Monad, NoConstraint, Pure, Satisfies,
};

// ============================================================================
// HKT Witness Implementation
// ============================================================================

pub struct CausalTensorWitness;

impl HKT for CausalTensorWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = CausalTensor<T>
    where
        T: Satisfies<NoConstraint>;
}

// ============================================================================
// Algebraic Implementations
// ============================================================================

impl Functor<CausalTensorWitness> for CausalTensorWitness {
    fn fmap<A, B, Func>(m_a: CausalTensor<A>, f: Func) -> CausalTensor<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        let shape = m_a.shape().to_vec();
        let new_data: Vec<B> = m_a.into_vec().into_iter().map(f).collect();
        CausalTensor::from_vec(new_data, &shape)
    }
}

impl Foldable<CausalTensorWitness> for CausalTensorWitness {
    fn fold<A, B, Func>(fa: CausalTensor<A>, init: B, f: Func) -> B
    where
        A: Satisfies<NoConstraint>,
        Func: FnMut(B, A) -> B,
    {
        fa.into_vec().into_iter().fold(init, f)
    }
}

impl Pure<CausalTensorWitness> for CausalTensorWitness {
    fn pure<T>(value: T) -> CausalTensor<T>
    where
        T: Satisfies<NoConstraint>,
    {
        CausalTensor::from_vec(vec![value], &[])
    }
}

impl Monad<CausalTensorWitness> for CausalTensorWitness {
    fn bind<A, B, Func>(m_a: CausalTensor<A>, mut f: Func) -> CausalTensor<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> <Self as HKT>::Type<B>,
    {
        let mut result_data = Vec::with_capacity(m_a.len());
        for a in m_a.into_vec() {
            let mb = f(a);
            result_data.extend(mb.into_vec());
        }
        let len = result_data.len();
        CausalTensor::from_vec(result_data, &[len])
    }
}

impl CoMonad<CausalTensorWitness> for CausalTensorWitness {
    fn extract<A>(fa: &CausalTensor<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        fa.as_slice()
            .first()
            .cloned()
            .expect("CoMonad::extract cannot be called on an empty CausalTensor.")
    }

    fn extend<A, B, Func>(fa: &CausalTensor<A>, mut f: Func) -> CausalTensor<B>
    where
        Func: FnMut(&CausalTensor<A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        let len = fa.len();
        let shape = fa.shape().to_vec();
        let new_data: Vec<B> = (0..len)
            .map(|i| {
                let view = fa.shifted_view(i);
                f(&view)
            })
            .collect();
        CausalTensor::from_vec(new_data, &shape)
    }
}

impl Applicative<CausalTensorWitness> for CausalTensorWitness {
    fn apply<A, B, Func>(f_ab: CausalTensor<Func>, f_a: CausalTensor<A>) -> CausalTensor<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> B,
    {
        let shape = f_a.shape().to_vec();
        let funcs = f_ab.into_vec();
        let args = f_a.into_vec();

        if funcs.len() == args.len() {
            let data: Vec<B> = funcs.into_iter().zip(args).map(|(mut f, a)| f(a)).collect();
            CausalTensor::from_vec(data, &shape)
        } else if funcs.len() == 1 {
            let f = funcs.into_iter().next().unwrap();
            let data: Vec<B> = args.into_iter().map(f).collect();
            CausalTensor::from_vec(data, &shape)
        } else {
            // Return empty tensor on mismatch, as expected by tests
            CausalTensor::from_vec(vec![], &[0])
        }
    }
}
