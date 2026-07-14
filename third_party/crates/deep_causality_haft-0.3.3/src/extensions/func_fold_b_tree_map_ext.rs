/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Foldable, Functor, HKT, HKT2, NoConstraint, Placeholder, Satisfies};
use alloc::collections::BTreeMap;

/// `BTreeMapWitness<K>` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `BTreeMap<K, V>` type constructor, where the key type `K` is fixed.
///
/// It allows `BTreeMap` to be used with generic functional programming traits like `Functor`
/// and `Foldable` by fixing one of its type parameters.
///
/// # Constraint
///
/// `BTreeMapWitness` uses `NoConstraint`, meaning it works with any value type `V`.
pub struct BTreeMapWitness<K>(Placeholder, K);

impl<K> HKT2<K> for BTreeMapWitness<K> {
    /// Specifies that `BTreeMapWitness<K>` represents the `BTreeMap<K, V>` type constructor
    /// with a fixed key type `K`.
    type Type<V> = BTreeMap<K, V>;
}

impl<K> HKT for BTreeMapWitness<K> {
    type Constraint = NoConstraint;

    /// Specifies that `BTreeMapWitness<K>` also acts as a single-parameter HKT,
    /// where the `K` parameter is considered part of the "witness" itself.
    type Type<V> = BTreeMap<K, V>;
}

// Implementation of Functor for BTreeMapWitness
impl<K> Functor<BTreeMapWitness<K>> for BTreeMapWitness<K>
where
    K: Ord + Clone + 'static,
{
    /// Implements the `fmap` operation for `BTreeMap<K, V>`.
    ///
    /// Applies the function `f` to each value in the B-tree map, producing a new B-tree map
    /// with the same keys but transformed values.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The `BTreeMap` to map over.
    /// *   `f`: The function to apply to each value.
    ///
    /// # Returns
    ///
    /// A new `BTreeMap` with the function applied to each of its values.
    fn fmap<A, B, Func>(
        m_a: <BTreeMapWitness<K> as HKT2<K>>::Type<A>,
        mut f: Func,
    ) -> <BTreeMapWitness<K> as HKT2<K>>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        m_a.into_iter().map(|(k, v)| (k, f(v))).collect()
    }
}

// Implementation of Foldable for BTreeMapWitness
impl<K> Foldable<BTreeMapWitness<K>> for BTreeMapWitness<K>
where
    K: Ord + 'static,
{
    /// Folds (reduces) a `BTreeMap` into a single value.
    ///
    /// Applies the function `f` cumulatively to the accumulator and each key-value pair
    /// of the B-tree map, starting with an initial accumulator value.
    ///
    /// # Arguments
    ///
    /// *   `fa`: The `BTreeMap` to fold.
    /// *   `init`: The initial accumulator value.
    /// *   `f`: The folding function, which takes the accumulator and a key-value pair.
    ///
    /// # Returns
    ///
    /// The final accumulated value after processing all elements.
    fn fold<A, B, Func>(fa: BTreeMap<K, A>, init: B, f: Func) -> B
    where
        Func: FnMut(B, A) -> B,
    {
        fa.into_values().fold(init, f)
    }
}
