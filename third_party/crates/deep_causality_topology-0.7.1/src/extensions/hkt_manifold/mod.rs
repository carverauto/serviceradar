/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! HKT witnesses for `Manifold`.
//!
//! Under the Option 2C design (`ChainComplex::Metric` is a plain associated type;
//! `Manifold<K, F>` has no struct-level bound on `F`), the witness types implement the
//! full `deep_causality_haft` trait surface on stable Rust: `HKT`, `Functor`, `Foldable`,
//! `Pure`, `Monad`, `CoMonad`, and (for the simplicial witness) `Applicative`. All impls
//! use `T: Satisfies<NoConstraint>` only — no `RealField` bounds at the witness layer.
//!
//! Cross-algebra composition is supported by design: `F` may be a scalar (`f64`, `f32`,
//! `Float106`), a multivector from `deep_causality_multivector`, a tensor from
//! `deep_causality_tensor`, a dual number for automatic differentiation, or any other
//! algebraic value type that flows through `CausalTensor<F>`.

use crate::traits::chain_complex::ChainComplex;
use crate::{Manifold, SimplicialComplex};
use deep_causality_haft::{
    Applicative, CoMonad, Foldable, Functor, HKT, Monad, NoConstraint, Pure, Satisfies,
};
use deep_causality_tensor::{CausalTensor, CausalTensorWitness};
use std::marker::PhantomData;

// ============================================================================
// PART 1: Simplicial witness — `ManifoldWitness<C>` / `SimplicialManifoldWitness<C>`
// ============================================================================

pub struct ManifoldWitness<C>(PhantomData<C>);

/// Textbook alias for the simplicial case.
pub type SimplicialManifoldWitness<C> = ManifoldWitness<C>;

impl<C> HKT for ManifoldWitness<C>
where
    SimplicialComplex<C>: ChainComplex,
    C: Satisfies<NoConstraint>
        + deep_causality_algebra::RealField
        + deep_causality_num::FromPrimitive,
{
    type Constraint = NoConstraint;
    type Type<T>
        = Manifold<SimplicialComplex<C>, T>
    where
        T: Satisfies<NoConstraint>;
}

impl<C> Functor<ManifoldWitness<C>> for ManifoldWitness<C>
where
    SimplicialComplex<C>: ChainComplex + Clone,
    <SimplicialComplex<C> as ChainComplex>::Metric: Clone,
    C: Satisfies<NoConstraint>
        + Clone
        + deep_causality_algebra::RealField
        + deep_causality_num::FromPrimitive,
{
    fn fmap<A, B, Func>(
        m_a: Manifold<SimplicialComplex<C>, A>,
        f: Func,
    ) -> Manifold<SimplicialComplex<C>, B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        // Metric is preserved across fmap: under Option 2C, `K::Metric` is a single
        // concrete type independent of the data type, so the metric clones through.
        let new_data_tensor = CausalTensorWitness::fmap(m_a.data, f);
        Manifold {
            complex: m_a.complex.clone(),
            data: new_data_tensor,
            metric: m_a.metric.clone(),
            cursor: m_a.cursor,
        }
    }
}

impl<C> Foldable<ManifoldWitness<C>> for ManifoldWitness<C>
where
    SimplicialComplex<C>: ChainComplex,
    C: Satisfies<NoConstraint>
        + deep_causality_algebra::RealField
        + deep_causality_num::FromPrimitive,
{
    fn fold<A, B, Func>(fa: Manifold<SimplicialComplex<C>, A>, init: B, f: Func) -> B
    where
        A: Satisfies<NoConstraint>,
        Func: FnMut(B, A) -> B,
    {
        fa.data.into_vec().into_iter().fold(init, f)
    }
}

impl<C> Pure<ManifoldWitness<C>> for ManifoldWitness<C>
where
    SimplicialComplex<C>: ChainComplex + Default,
    C: Satisfies<NoConstraint>
        + Default
        + deep_causality_algebra::RealField
        + deep_causality_num::FromPrimitive,
{
    fn pure<T>(value: T) -> Manifold<SimplicialComplex<C>, T>
    where
        T: Satisfies<NoConstraint>,
    {
        let tensor = CausalTensor::from_vec(vec![value], &[1]);
        Manifold {
            complex: Default::default(),
            data: tensor,
            metric: None,
            cursor: 0,
        }
    }
}

impl<C> Monad<ManifoldWitness<C>> for ManifoldWitness<C>
where
    SimplicialComplex<C>: ChainComplex + Clone + Default,
    <SimplicialComplex<C> as ChainComplex>::Metric: Clone,
    C: Satisfies<NoConstraint>
        + Clone
        + Default
        + deep_causality_algebra::RealField
        + deep_causality_num::FromPrimitive,
{
    fn bind<A, B, Func>(
        m_a: Manifold<SimplicialComplex<C>, A>,
        mut f: Func,
    ) -> Manifold<SimplicialComplex<C>, B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> <Self as HKT>::Type<B>,
    {
        let mut result_data = Vec::with_capacity(m_a.data.len());
        for a in m_a.data.into_vec() {
            let mb = f(a);
            result_data.extend(mb.data.into_vec());
        }
        let new_len = result_data.len();
        let new_tensor = CausalTensor::from_vec(result_data, &[new_len]);
        Manifold {
            complex: m_a.complex.clone(),
            data: new_tensor,
            metric: m_a.metric.clone(),
            cursor: 0,
        }
    }
}

impl<C> Applicative<ManifoldWitness<C>> for ManifoldWitness<C>
where
    SimplicialComplex<C>: ChainComplex + Clone + Default,
    <SimplicialComplex<C> as ChainComplex>::Metric: Clone,
    C: Satisfies<NoConstraint>
        + Clone
        + Default
        + deep_causality_algebra::RealField
        + deep_causality_num::FromPrimitive,
{
    fn apply<A, B, Func>(
        f_ab: Manifold<SimplicialComplex<C>, Func>,
        f_a: Manifold<SimplicialComplex<C>, A>,
    ) -> Manifold<SimplicialComplex<C>, B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> B,
    {
        let shape = f_a.data.shape().to_vec();
        let funcs = f_ab.data.into_vec();
        let args = f_a.data.into_vec();

        let new_data: Vec<B> = if funcs.len() == 1 {
            let f = funcs.into_iter().next().unwrap();
            args.into_iter().map(f).collect()
        } else {
            funcs.into_iter().zip(args).map(|(mut f, a)| f(a)).collect()
        };

        let new_tensor = CausalTensor::from_vec(new_data, &shape);
        Manifold {
            complex: f_a.complex.clone(),
            data: new_tensor,
            metric: f_a.metric.clone(),
            cursor: 0,
        }
    }
}

impl<C> CoMonad<ManifoldWitness<C>> for ManifoldWitness<C>
where
    SimplicialComplex<C>: ChainComplex + Clone,
    <SimplicialComplex<C> as ChainComplex>::Metric: Clone,
    C: Satisfies<NoConstraint>
        + Clone
        + deep_causality_algebra::RealField
        + deep_causality_num::FromPrimitive,
{
    fn extract<A>(fa: &Manifold<SimplicialComplex<C>, A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        if fa.data.is_empty() {
            panic!("Cannot extract from empty Manifold");
        }
        fa.data
            .as_slice()
            .get(fa.cursor)
            .cloned()
            .expect("Cursor out of bounds")
    }

    fn extend<A, B, Func>(
        fa: &Manifold<SimplicialComplex<C>, A>,
        mut f: Func,
    ) -> Manifold<SimplicialComplex<C>, B>
    where
        Func: FnMut(&Manifold<SimplicialComplex<C>, A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        let len = fa.data.len();
        let shape = fa.data.shape().to_vec();
        let new_data: Vec<B> = (0..len)
            .map(|i| {
                let mut view = fa.clone_shallow();
                view.cursor = i;
                f(&view)
            })
            .collect();
        let new_tensor = CausalTensor::from_vec(new_data, &shape);
        Manifold {
            complex: fa.complex.clone(),
            data: new_tensor,
            metric: fa.metric.clone(),
            cursor: fa.cursor,
        }
    }
}

// ============================================================================
// PART 2: Generic witness — `GenericManifoldWitness<K>` over any `ChainComplex`
// ============================================================================

pub struct GenericManifoldWitness<K>(PhantomData<K>);

impl<K> HKT for GenericManifoldWitness<K>
where
    K: ChainComplex + Satisfies<NoConstraint>,
{
    type Constraint = NoConstraint;
    type Type<T>
        = Manifold<K, T>
    where
        T: Satisfies<NoConstraint>;
}

impl<K> Functor<GenericManifoldWitness<K>> for GenericManifoldWitness<K>
where
    K: ChainComplex + Satisfies<NoConstraint> + Clone,
    K::Metric: Clone,
{
    fn fmap<A, B, Func>(m_a: Manifold<K, A>, f: Func) -> Manifold<K, B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        let new_data_tensor = CausalTensorWitness::fmap(m_a.data, f);
        Manifold {
            complex: m_a.complex.clone(),
            data: new_data_tensor,
            metric: m_a.metric.clone(),
            cursor: m_a.cursor,
        }
    }
}

// `Pure`, `Monad`, `Applicative`, `CoMonad` impls for `GenericManifoldWitness<K>` remain
// deferred to a follow-up: `Pure` needs `K: Default` and the others need additional
// bounds that don't fall out generically. The simplicial fast path covers the common
// case via `SimplicialManifoldWitness<C>`.
