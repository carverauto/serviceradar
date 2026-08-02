/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Higher-kinded-type witness and comonad instance for [`MixedGraph`].
//!
//! Mirrors [`crate::GraphWitness`]: `MixedGraph` is a `Functor` over its node
//! payload and a `CoMonad` focused by its cursor, so it joins the same
//! higher-kinded-type machinery as `Graph` and `Hypergraph`.

use crate::MixedGraph;
use deep_causality_haft::{CoMonad, Functor, HKT, NoConstraint, Satisfies};
use deep_causality_tensor::{CausalTensor, CausalTensorWitness};

/// HKT witness for [`MixedGraph`]: `Type<T> = MixedGraph<T>`.
pub struct MixedGraphWitness;

impl HKT for MixedGraphWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = MixedGraph<T>
    where
        T: Satisfies<NoConstraint>;
}

impl Functor<MixedGraphWitness> for MixedGraphWitness {
    fn fmap<A, B, F>(fa: MixedGraph<A>, f: F) -> MixedGraph<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        F: FnMut(A) -> B,
    {
        let new_data = CausalTensorWitness::fmap(fa.data, f);
        MixedGraph {
            num_vertices: fa.num_vertices,
            edges: fa.edges,
            data: new_data,
            cursor: fa.cursor,
        }
    }
}

impl CoMonad<MixedGraphWitness> for MixedGraphWitness {
    fn extract<A>(fa: &MixedGraph<A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        fa.data
            .as_slice()
            .get(fa.cursor)
            .cloned()
            .expect("Cursor OOB")
    }

    fn extend<A, B, Func>(fa: &MixedGraph<A>, mut f: Func) -> MixedGraph<B>
    where
        Func: FnMut(&MixedGraph<A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        let size = fa.num_vertices;
        let shape = fa.data.shape().to_vec();
        let mut result_vec = Vec::with_capacity(size);

        for i in 0..size {
            let mut view = fa.clone_shallow();
            view.cursor = i;
            result_vec.push(f(&view));
        }

        let new_data = CausalTensor::from_vec(result_vec, &shape);

        MixedGraph {
            num_vertices: fa.num_vertices,
            edges: fa.edges.clone(),
            data: new_data,
            // Preserve the focus: position `p` of the result holds `f` evaluated
            // with the focus at `p`, and the result keeps `fa`'s focus. This is
            // what makes `extend` satisfy the comonad laws (right identity and
            // associativity); resetting to `0` would break them for a non-zero
            // focus.
            cursor: fa.cursor,
        }
    }
}
