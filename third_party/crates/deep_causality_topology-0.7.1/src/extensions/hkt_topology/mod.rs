/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Topology;
use deep_causality_haft::{CoMonad, Functor, HKT, NoConstraint, Satisfies};
use deep_causality_tensor::{CausalTensor, CausalTensorWitness};
use std::sync::Arc;

pub struct TopologyWitness;

impl HKT for TopologyWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = Topology<T>
    where
        T: Satisfies<NoConstraint>;
}

impl Functor<TopologyWitness> for TopologyWitness {
    fn fmap<A, B, F>(fa: Topology<A>, f: F) -> Topology<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        F: FnMut(A) -> B,
    {
        // Map Data
        let new_data = CausalTensorWitness::fmap(fa.data, f);

        // Map Complex
        // We cannot use fa.complex.map(f) because A might not be Clone, equality of A and B is not guaranteed,
        // and Arc prevents consuming the inner value.
        // Thus, we reconstruct the topological structure (skeletons/boundaries) which is invariant,
        // and drop the geometric structure (hodge operators) which depends on A.
        let new_complex = crate::SimplicialComplex::<B> {
            skeletons: fa.complex.skeletons.clone(),
            boundary_operators: fa.complex.boundary_operators.clone(),
            coboundary_operators: fa.complex.coboundary_operators.clone(),
            ..Default::default()
        };

        Topology {
            complex: Arc::new(new_complex),
            grade: fa.grade,
            data: new_data,
            cursor: fa.cursor,
        }
    }
}

impl CoMonad<TopologyWitness> for TopologyWitness {
    fn extract<A>(fa: &Topology<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        fa.data
            .as_slice()
            .get(fa.cursor)
            .cloned()
            .expect("Cursor OOB")
    }

    fn extend<A, B, Func>(fa: &Topology<A>, mut f: Func) -> Topology<B>
    where
        Func: FnMut(&Topology<A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        let size = fa.data.len();
        let shape = fa.data.shape().to_vec();
        let mut result_vec = Vec::with_capacity(size);

        for i in 0..size {
            let mut view = fa.clone_shallow();
            view.cursor = i;

            let val = f(&view);
            result_vec.push(val);
        }

        // Reconstruct complex for B
        // Preserve topology from A
        let new_complex = crate::SimplicialComplex::<B> {
            skeletons: fa.complex.skeletons.clone(),
            boundary_operators: fa.complex.boundary_operators.clone(),
            coboundary_operators: fa.complex.coboundary_operators.clone(),
            ..Default::default()
        };

        Topology {
            complex: Arc::new(new_complex),
            grade: fa.grade,
            data: CausalTensor::from_vec(result_vec, &shape),
            // Preserve the focus so `extend` satisfies the comonad laws (right
            // identity and associativity); resetting to `0` breaks them for a
            // non-zero focus.
            cursor: fa.cursor,
        }
    }
}
