/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Graph;
use deep_causality_haft::{CoMonad, Functor, HKT, NoConstraint, Satisfies};
use deep_causality_tensor::{CausalTensor, CausalTensorWitness};

pub struct GraphWitness;

impl HKT for GraphWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = Graph<T>
    where
        T: Satisfies<NoConstraint>;
}

impl Functor<GraphWitness> for GraphWitness {
    fn fmap<A, B, F>(fa: Graph<A>, f: F) -> Graph<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        F: FnMut(A) -> B,
    {
        let new_data = CausalTensorWitness::fmap(fa.data, f);
        Graph {
            num_vertices: fa.num_vertices,
            adjacencies: fa.adjacencies,
            num_edges: fa.num_edges,
            data: new_data,
            cursor: fa.cursor,
        }
    }
}

impl CoMonad<GraphWitness> for GraphWitness {
    fn extract<A>(fa: &Graph<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        fa.data
            .as_slice()
            .get(fa.cursor)
            .cloned()
            .expect("Cursor OOB")
    }

    fn extend<A, B, Func>(fa: &Graph<A>, mut f: Func) -> Graph<B>
    where
        Func: FnMut(&Graph<A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        let size = fa.num_vertices;
        let shape = fa.data.shape().to_vec();
        let mut result_vec = Vec::with_capacity(size);

        for i in 0..size {
            let mut view = fa.clone_shallow();
            view.cursor = i;

            let val = f(&view);
            result_vec.push(val);
        }

        let new_data = CausalTensor::from_vec(result_vec, &shape);

        Graph {
            num_vertices: fa.num_vertices,
            adjacencies: fa.adjacencies.clone(),
            num_edges: fa.num_edges,
            data: new_data,
            // Preserve the focus so `extend` satisfies the comonad laws (right
            // identity and associativity); resetting to `0` breaks them for a
            // non-zero focus.
            cursor: fa.cursor,
        }
    }
}
