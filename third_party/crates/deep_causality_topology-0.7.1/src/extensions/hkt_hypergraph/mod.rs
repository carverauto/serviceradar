/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Hypergraph;
use deep_causality_haft::{CoMonad, Functor, HKT, NoConstraint, Satisfies};
use deep_causality_tensor::{CausalTensor, CausalTensorWitness};

pub struct HypergraphWitness;

impl HKT for HypergraphWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = Hypergraph<T>
    where
        T: Satisfies<NoConstraint>;
}

impl Functor<HypergraphWitness> for HypergraphWitness {
    fn fmap<A, B, F>(fa: Hypergraph<A>, f: F) -> Hypergraph<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        F: FnMut(A) -> B,
    {
        let new_data = CausalTensorWitness::fmap(fa.data, f);
        Hypergraph {
            num_nodes: fa.num_nodes,
            num_hyperedges: fa.num_hyperedges,
            incidence: fa.incidence,
            data: new_data,
            cursor: fa.cursor,
        }
    }
}

impl CoMonad<HypergraphWitness> for HypergraphWitness {
    fn extract<A>(fa: &Hypergraph<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        fa.data
            .as_slice()
            .get(fa.cursor)
            .cloned()
            .expect("Cursor OOB")
    }

    fn extend<A, B, Func>(fa: &Hypergraph<A>, mut f: Func) -> Hypergraph<B>
    where
        Func: FnMut(&Hypergraph<A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        let size = fa.num_nodes;
        let shape = fa.data.shape().to_vec();
        let mut result_vec = Vec::with_capacity(size);

        for i in 0..size {
            let mut view = fa.clone_shallow();
            view.cursor = i;

            let val = f(&view);
            result_vec.push(val);
        }

        let new_data = CausalTensor::from_vec(result_vec, &shape);

        Hypergraph {
            num_nodes: fa.num_nodes,
            num_hyperedges: fa.num_hyperedges,
            incidence: fa.incidence.clone(),
            data: new_data,
            // Preserve the focus so `extend` satisfies the comonad laws (right
            // identity and associativity); resetting to `0` breaks them for a
            // non-zero focus.
            cursor: fa.cursor,
        }
    }
}
