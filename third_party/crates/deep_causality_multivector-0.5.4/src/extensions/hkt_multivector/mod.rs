/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalMultiVector;
use deep_causality_haft::{
    Adjunction, Applicative, CoMonad, Foldable, Functor, HKT, Monad, NoConstraint, Pure, Satisfies,
};
use deep_causality_metric::Metric;

pub struct CausalMultiVectorWitness;

impl HKT for CausalMultiVectorWitness {
    type Constraint = NoConstraint;
    type Type<T> = CausalMultiVector<T>;
}

// ----------------------------------------------------------------------------
// Functor
// ----------------------------------------------------------------------------
impl Functor<CausalMultiVectorWitness> for CausalMultiVectorWitness {
    fn fmap<A, B, Func>(fa: CausalMultiVector<A>, f: Func) -> CausalMultiVector<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        let metric = fa.metric;
        let data = fa.data.into_iter().map(f).collect();
        CausalMultiVector { data, metric }
    }
}

// ----------------------------------------------------------------------------
// Pure
// ----------------------------------------------------------------------------
impl Pure<CausalMultiVectorWitness> for CausalMultiVectorWitness {
    fn pure<T>(value: T) -> CausalMultiVector<T>
    where
        T: Satisfies<NoConstraint>,
    {
        let metric = Metric::Euclidean(0);
        let data = vec![value];
        CausalMultiVector { data, metric }
    }
}

// ----------------------------------------------------------------------------
// Applicative
// ----------------------------------------------------------------------------
impl Applicative<CausalMultiVectorWitness> for CausalMultiVectorWitness {
    fn apply<A, B, Func>(
        f_ab: CausalMultiVector<Func>,
        f_a: CausalMultiVector<A>,
    ) -> CausalMultiVector<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: Satisfies<NoConstraint> + FnMut(A) -> B,
    {
        let metric = f_a.metric;
        let funcs = f_ab.data;
        let args = f_a.data;

        let data = if funcs.len() == 1 {
            let f = funcs.into_iter().next().unwrap();
            args.into_iter().map(f).collect()
        } else if funcs.len() == args.len() {
            funcs.into_iter().zip(args).map(|(mut f, a)| f(a)).collect()
        } else {
            panic!(
                "Applicative::apply shape mismatch: {} funcs vs {} args",
                funcs.len(),
                args.len()
            );
        };

        CausalMultiVector { data, metric }
    }
}

// ----------------------------------------------------------------------------
// Foldable
// ----------------------------------------------------------------------------
impl Foldable<CausalMultiVectorWitness> for CausalMultiVectorWitness {
    fn fold<A, B, Func>(fa: CausalMultiVector<A>, init: B, f: Func) -> B
    where
        A: Satisfies<NoConstraint>,
        Func: FnMut(B, A) -> B,
    {
        fa.data.into_iter().fold(init, f)
    }
}

// ----------------------------------------------------------------------------
// Monad
// ----------------------------------------------------------------------------
impl Monad<CausalMultiVectorWitness> for CausalMultiVectorWitness {
    fn bind<A, B, Func>(ma: CausalMultiVector<A>, mut f: Func) -> CausalMultiVector<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> CausalMultiVector<B>,
    {
        let mut results = Vec::new();
        let mut out_metric = ma.metric;

        for a in ma.data {
            let mb = f(a);
            out_metric = mb.metric;
            results.extend(mb.data);
        }

        CausalMultiVector {
            data: results,
            metric: out_metric,
        }
    }
}

// ----------------------------------------------------------------------------
// CoMonad
// ----------------------------------------------------------------------------
impl CoMonad<CausalMultiVectorWitness> for CausalMultiVectorWitness {
    fn extract<A>(fa: &CausalMultiVector<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        // Extract scalar part (index 0)
        fa.data.first().cloned().expect("Empty MultiVector")
    }

    fn extend<A, B, Func>(fa: &CausalMultiVector<A>, mut f: Func) -> CausalMultiVector<B>
    where
        Func: FnMut(&CausalMultiVector<A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        // Extend with cyclic rotation.
        // For each position i, construct a view where i is the new origin (0).
        // For a MultiVector, this is "Basis Shifting".
        // view[k] = fa[(i + k) % N]
        let n = fa.data.len();
        let mut result_data = Vec::with_capacity(n);

        for i in 0..n {
            // Create rotated view
            let mut rotated_data = Vec::with_capacity(n);
            for k in 0..n {
                let idx = (i + k) % n;
                rotated_data.push(fa.data[idx].clone());
            }
            let view = CausalMultiVector {
                data: rotated_data,
                metric: fa.metric,
            };

            result_data.push(f(&view));
        }

        CausalMultiVector {
            data: result_data,
            metric: fa.metric,
        }
    }
}

// ----------------------------------------------------------------------------
// Adjunction
// ----------------------------------------------------------------------------
// Context: Metric (defining the space we are adjoint to)
impl Adjunction<CausalMultiVectorWitness, CausalMultiVectorWitness, Metric>
    for CausalMultiVectorWitness
{
    fn unit<A>(ctx: &Metric, a: A) -> CausalMultiVector<CausalMultiVector<A>>
    where
        A: Satisfies<NoConstraint> + Satisfies<NoConstraint> + Clone,
    {
        // unit: a -> R(L(a))
        // Inner MV: Context metric, contains 'a'.
        let inner_data = vec![a];
        let inner_mv = CausalMultiVector {
            data: inner_data,
            metric: *ctx,
        };

        // Outer MV: Scalar metric, contains inner_mv.
        let outer_data = vec![inner_mv];
        CausalMultiVector {
            data: outer_data,
            metric: Metric::Euclidean(0),
        }
    }

    fn counit<B>(_ctx: &Metric, lrb: CausalMultiVector<CausalMultiVector<B>>) -> B
    where
        B: Satisfies<NoConstraint> + Satisfies<NoConstraint> + Clone,
    {
        // counit: L(R(b)) -> b
        // Flatten and extract.
        let flattened =
            <CausalMultiVectorWitness as Monad<CausalMultiVectorWitness>>::bind(lrb, |x| x);
        <CausalMultiVectorWitness as CoMonad<CausalMultiVectorWitness>>::extract(&flattened)
    }

    fn left_adjunct<A, B, F>(ctx: &Metric, a: A, f: F) -> CausalMultiVector<B>
    where
        A: Satisfies<NoConstraint> + Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        F: Fn(CausalMultiVector<A>) -> B,
    {
        // left: a -> f(unit(a))
        let unit_res = Self::unit(ctx, a);
        Self::fmap(unit_res, f)
    }

    fn right_adjunct<A, B, F>(_ctx: &Metric, la: CausalMultiVector<A>, f: F) -> B
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint> + Satisfies<NoConstraint>,
        F: FnMut(A) -> CausalMultiVector<B>,
    {
        // right: (A -> R<B>) -> (L<A> -> B)
        // map la with f -> L<R<B>> (MV<MV<B>>)
        // then extract manually to avoid Clone requirement of counit.
        let mapped = Self::fmap(la, f);

        // Destructure Outer MV
        let mut outer_iter = mapped.data.into_iter();
        if let Some(inner_mv) = outer_iter.next() {
            // Destructure Inner MV
            let mut inner_iter = inner_mv.data.into_iter();
            if let Some(b) = inner_iter.next() {
                return b;
            }
        }
        panic!("Adjunction::right_adjunct resulted in empty MultiVector");
    }
}
