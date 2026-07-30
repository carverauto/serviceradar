/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Chain, SimplicialComplex};
use deep_causality_haft::{
    Adjunction, CoMonad, Foldable, Functor, HKT, NoConstraint, Pure, Satisfies,
};
use deep_causality_sparse::CsrMatrixWitness;
use std::sync::Arc;

pub struct ChainWitness;

impl HKT for ChainWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = Chain<T>
    where
        T: Satisfies<NoConstraint>;
}

// ----------------------------------------------------------------------------
// Functor
// ----------------------------------------------------------------------------

impl Functor<ChainWitness> for ChainWitness {
    fn fmap<A, B, Func>(fa: Chain<A>, f: Func) -> Chain<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>, // Removed strict bounds
        Func: FnMut(A) -> B,
    {
        // Re-use CsrMatrix functor logic on weights to apply f(a) -> b
        let new_weights = <CsrMatrixWitness as Functor<CsrMatrixWitness>>::fmap(fa.weights, f);
        // Structural copy without Hodge ⋆ or geometric data. The lazy accessor
        // returns an Err("geometric data not available") if a consumer tries to
        // read Hodge ⋆ from this functor-mapped complex; mapped chains are not
        // intended to drive DEC pipelines.
        let new_complex = SimplicialComplex::<B> {
            skeletons: fa.complex.skeletons.clone(),
            boundary_operators: fa.complex.boundary_operators.clone(),
            coboundary_operators: fa.complex.coboundary_operators.clone(),
            ..Default::default()
        };

        Chain::new(Arc::new(new_complex), fa.grade, new_weights)
    }
}

// ----------------------------------------------------------------------------
// Foldable
// ----------------------------------------------------------------------------

impl Foldable<ChainWitness> for ChainWitness {
    fn fold<A, B, Func>(fa: Chain<A>, init: B, f: Func) -> B
    where
        A: Satisfies<NoConstraint>,
        Func: FnMut(B, A) -> B,
    {
        // Re-use CsrMatrix foldable logic
        <CsrMatrixWitness as Foldable<CsrMatrixWitness>>::fold(fa.weights, init, f)
    }
}

// ----------------------------------------------------------------------------
// Adjunction
// ----------------------------------------------------------------------------
// Context: (Complex, Grade)

impl<T> Adjunction<ChainWitness, ChainWitness, (Arc<SimplicialComplex<T>>, usize)> for ChainWitness
where
    T: Satisfies<NoConstraint>,
{
    fn unit<A>(ctx: &(Arc<SimplicialComplex<T>>, usize), a: A) -> Chain<Chain<A>>
    where
        A: Satisfies<NoConstraint> + Satisfies<NoConstraint> + Clone,
        // We remove unnecessary recursive bounds if possible.
    {
        let (complex, grade) = ctx;

        // Inner Complex: Complex<A>.
        // We construct a structural copy without hodge stars.
        let complex_a = SimplicialComplex::<A> {
            skeletons: complex.skeletons.clone(),
            boundary_operators: complex.boundary_operators.clone(),
            coboundary_operators: complex.coboundary_operators.clone(),
            ..Default::default()
        };
        let arc_complex_a = Arc::new(complex_a);

        let inner_weights = <CsrMatrixWitness as Pure<CsrMatrixWitness>>::pure(a);
        let inner_chain = Chain::new(arc_complex_a.clone(), *grade, inner_weights);

        // Outer Complex: Complex<Chain<A>>.
        // Structural copy.
        let complex_chain_a = SimplicialComplex::<Chain<A>> {
            skeletons: complex.skeletons.clone(),
            boundary_operators: complex.boundary_operators.clone(),
            coboundary_operators: complex.coboundary_operators.clone(),
            ..Default::default()
        };

        let outer_weights = <CsrMatrixWitness as Pure<CsrMatrixWitness>>::pure(inner_chain);
        Chain::new(Arc::new(complex_chain_a), *grade, outer_weights)
    }

    fn counit<B>(_ctx: &(Arc<SimplicialComplex<T>>, usize), lrb: Chain<Chain<B>>) -> B
    where
        B: Satisfies<NoConstraint> + Satisfies<NoConstraint> + Clone,
    {
        // counit: Chain<Chain<B>> -> B
        let inner_chain = <CsrMatrixWitness as CoMonad<CsrMatrixWitness>>::extract(&lrb.weights);
        <CsrMatrixWitness as CoMonad<CsrMatrixWitness>>::extract(&inner_chain.weights)
    }

    fn left_adjunct<A, B, F>(ctx: &(Arc<SimplicialComplex<T>>, usize), a: A, f: F) -> Chain<B>
    where
        A: Satisfies<NoConstraint> + Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        F: FnMut(Chain<A>) -> B,
    {
        // left: a -> f(unit(a))
        let wrapped = Self::unit(ctx, a);
        Self::fmap(wrapped, f)
    }

    fn right_adjunct<A, B, F>(_ctx: &(Arc<SimplicialComplex<T>>, usize), la: Chain<A>, f: F) -> B
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint> + Satisfies<NoConstraint> + Clone, // B needs Clone for unit in recursion if logic implies
        F: FnMut(A) -> Chain<B>,
    {
        // right: (A -> R<B>) -> (L<A> -> B)
        let result_chain: Chain<Chain<B>> = Self::fmap(la, f);

        // Unpack manually
        let (_, _, outer_values, _) = result_chain.weights.into_parts();

        if let Some(inner_chain) = outer_values.into_iter().next() {
            let (_, _, inner_values, _) = inner_chain.weights.into_parts();
            if let Some(val) = inner_values.into_iter().next() {
                return val;
            }
        }

        panic!("Adjunction::right_adjunct resulted in empty chain.");
    }
}
