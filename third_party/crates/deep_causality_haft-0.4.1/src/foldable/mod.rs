/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{HKT, Satisfies};
use deep_causality_algebra::Monoid;

/// The `Foldable` trait abstracts over data structures that can be reduced to a single summary value.
///
/// It provides a `fold` operation (also known as `reduce` or `inject`) that applies a binary function
/// to an accumulator and each element of the structure, from left to right.
///
/// This trait is generic over `F`, which is a Higher-Kinded Type (HKT) witness.
///
/// # Laws (Informal)
///
/// 1.  **Fold identity**: `fold(pure(x), z, f) == f(z, x)` (for witnesses that also
///     implement `Pure`) — folding a singleton applies `f` exactly once.
///
/// Laws are stated for pure functions; a stateful `FnMut` closure voids them.
/// Machine-checked in `lean/DeepCausalityFormal/Haft/Foldable.lean`.
///
/// # Type Parameters
///
/// *   `F`: A Higher-Kinded Type (HKT) witness that represents the type constructor
///     (e.g., `OptionWitness`, `ResultWitness<E>`, `VecWitness`).
pub trait Foldable<F: HKT> {
    /// Reduces the elements of the structure to a single value by applying a function.
    ///
    /// This is equivalent to a left-fold (`foldl`) operation. It traverses the structure,
    /// applying the `f` function to an accumulating value and each element.
    ///
    /// # Arguments
    ///
    /// *   `fa`: The data structure (`F::Type<A>`) to fold.
    /// *   `init`: The initial value of the accumulator.
    /// *   `f`: A binary function that takes the current accumulator and an element
    ///     from the structure, and returns the new accumulator value.
    ///
    /// # Returns
    ///
    /// The final accumulated value after processing all elements.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: The type of the elements within the foldable structure.
    /// *   `B`: The type of the accumulator and the final result.
    /// *   `Func`: The type of the folding function, which must be `FnMut(B, A) -> B`.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use deep_causality_haft::{Foldable, OptionWitness};
    ///
    /// let opt = Some(5);
    /// let sum = OptionWitness::fold(opt, 0, |acc, x| acc + x);
    /// assert_eq!(sum, 5);
    ///
    /// let none_opt: Option<i32> = None;
    /// let sum_none = OptionWitness::fold(none_opt, 0, |acc, x| acc + x);
    /// assert_eq!(sum_none, 0);
    /// ```
    fn fold<A, B, Func>(fa: F::Type<A>, init: B, f: Func) -> B
    where
        A: Satisfies<F::Constraint>,
        Func: FnMut(B, A) -> B;

    /// Folds the structure into a monoid: maps each element into a `Monoid` `M` and combines the
    /// results, seeded with `M::empty()`.
    ///
    /// This is the monoidal fold (`foldMap` in the Haskell `Data.Foldable` tradition). It expresses a
    /// `Collection` as a fold-map into its aggregation monoid, and — because the accumulation is the
    /// monoid's associative `combine` from its `empty` identity — order-independence over a
    /// `CommutativeMonoid` reduces to the monoid laws.
    ///
    /// # Default
    ///
    /// Provided in terms of the seeded [`fold`](Foldable::fold) and the `Monoid` (`empty`/`combine`)
    /// from `deep_causality_algebra`:
    /// `fold_map(fa, f) = fold(fa, M::empty(), |acc, a| acc.combine(f(a)))`.
    ///
    /// # Laws
    ///
    /// 1. **Singleton**: `fold_map(pure(a), f) == f(a)` (via the monoid identity).
    /// 2. **Monoid-homomorphism coherence**: `fold_map` respects `empty`/`combine` — folding the empty
    ///    structure yields `M::empty()`, and concatenation maps to `combine`.
    ///
    /// Machine-checked in `lean/DeepCausalityFormal/Haft/Foldable.lean`.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: the element type of the foldable structure.
    /// *   `M`: the target `Monoid`.
    /// *   `Func`: the element-to-monoid map `Fn(A) -> M`.
    fn fold_map<A, M, Func>(fa: F::Type<A>, f: Func) -> M
    where
        A: Satisfies<F::Constraint>,
        M: Monoid,
        Func: Fn(A) -> M,
    {
        Self::fold(fa, M::empty(), |acc, a| acc.combine(f(a)))
    }
}
