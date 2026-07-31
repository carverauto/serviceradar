/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Foldable, Functor, HKT, HKT2, NoConstraint, Placeholder, Satisfies};
use std::collections::HashMap;
use std::hash::Hash;

/// `HashMapWitness<K>` is a zero-sized type that acts as a Higher-Kinded Type (HKT) witness
/// for the `HashMap<K, V>` type constructor, where the key type `K` is fixed.
///
/// It allows `HashMap` to be used with generic functional programming traits like `Functor`
/// and `Foldable` by fixing one of its type parameters.
///
/// # Constraint
///
/// `HashMapWitness` uses `NoConstraint`, meaning it works with any value type `V`.
pub struct HashMapWitness<K>(Placeholder, K);

impl<K> HKT2<K> for HashMapWitness<K> {
    /// Specifies that `HashMapWitness<K>` represents the `HashMap<K, V>` type constructor
    /// with a fixed key type `K`.
    type Type<V> = HashMap<K, V>;
}

impl<K> HKT for HashMapWitness<K> {
    type Constraint = NoConstraint;

    /// Specifies that `HashMapWitness<K>` also acts as a single-parameter HKT,
    /// where the `K` parameter is considered part of the "witness" itself.
    type Type<V> = HashMap<K, V>;
}

// Implementation of Functor for HashMapWitness
impl<K> Functor<HashMapWitness<K>> for HashMapWitness<K>
where
    K: Hash + Eq + Clone + 'static,
{
    /// Implements the `fmap` operation for `HashMap<K, V>`.
    ///
    /// Applies the function `f` to each value in the hash map, producing a new hash map
    /// with the same keys but transformed values.
    ///
    /// # Arguments
    ///
    /// *   `m_a`: The `HashMap` to map over.
    /// *   `f`: The function to apply to each value.
    ///
    /// # Returns
    ///
    /// A new `HashMap` with the function applied to each of its values.
    fn fmap<A, B, Func>(
        m_a: <HashMapWitness<K> as HKT2<K>>::Type<A>,
        mut f: Func,
    ) -> <HashMapWitness<K> as HKT2<K>>::Type<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        m_a.into_iter().map(|(k, v)| (k, f(v))).collect()
    }
}

// Implementation of Foldable for HashMapWitness
impl<K> Foldable<HashMapWitness<K>> for HashMapWitness<K>
where
    K: Hash + Eq + 'static,
{
    /// Folds (reduces) a `HashMap` into a single value.
    ///
    /// Applies the function `f` cumulatively to the accumulator and each key-value pair
    /// of the hash map, starting with an initial accumulator value.
    ///
    /// # Arguments
    ///
    /// *   `fa`: The `HashMap` to fold.
    /// *   `init`: The initial accumulator value.
    /// *   `f`: The folding function, which takes the accumulator and a key-value pair.
    ///
    /// # Returns
    ///
    /// The final accumulated value after processing all elements.
    fn fold<A, B, Func>(fa: HashMap<K, A>, init: B, f: Func) -> B
    where
        Func: FnMut(B, A) -> B,
    {
        fa.into_values().fold(init, f)
    }
}
