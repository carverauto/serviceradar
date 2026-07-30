/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::PointCloud;
use deep_causality_haft::{CoMonad, Functor, HKT, NoConstraint, Satisfies};
use deep_causality_tensor::{CausalTensor, CausalTensorWitness};
use std::marker::PhantomData;

pub struct PointCloudWitness<C>(PhantomData<C>);

impl<C> HKT for PointCloudWitness<C>
where
    C: Satisfies<NoConstraint>,
{
    type Constraint = NoConstraint;
    type Type<T>
        = PointCloud<C, T>
    where
        T: Satisfies<NoConstraint>;
}

impl<C> Functor<PointCloudWitness<C>> for PointCloudWitness<C>
where
    C: Satisfies<NoConstraint> + Clone,
{
    fn fmap<A, B, F>(fa: PointCloud<C, A>, f: F) -> PointCloud<C, B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        F: FnMut(A) -> B,
    {
        // Points are invariant
        let new_points = fa.points.clone();

        // Metadata is covariant
        let new_metadata = CausalTensorWitness::fmap(fa.metadata, f);

        PointCloud {
            points: new_points,
            metadata: new_metadata,
            cursor: fa.cursor,
        }
    }
}

impl<C> CoMonad<PointCloudWitness<C>> for PointCloudWitness<C>
where
    C: Satisfies<NoConstraint> + Clone,
{
    fn extract<A>(fa: &PointCloud<C, A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        fa.metadata
            .as_slice()
            .get(fa.cursor)
            .cloned()
            .expect("Cursor OOB")
    }

    fn extend<A, B, Func>(fa: &PointCloud<C, A>, mut f: Func) -> PointCloud<C, B>
    where
        Func: FnMut(&PointCloud<C, A>) -> B,
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
    {
        let size = fa.len();
        let shape = fa.metadata.shape().to_vec();
        let mut result_vec = Vec::with_capacity(size);

        for i in 0..size {
            let mut view = fa.clone_shallow();
            view.cursor = i;

            let val = f(&view);
            result_vec.push(val);
        }

        let new_metadata = CausalTensor::from_vec(result_vec, &shape);
        let new_points = fa.points.clone();

        PointCloud {
            points: new_points,
            metadata: new_metadata,
            // Preserve the focus so `extend` satisfies the comonad laws (right
            // identity and associativity); resetting to `0` breaks them for a
            // non-zero focus.
            cursor: fa.cursor,
        }
    }
}
