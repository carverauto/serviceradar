/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Applicative, Foldable, Functor, HKT, Satisfies};

/// The `Traversable` trait abstracts over data structures that can be "traversed"
/// or "sequenced" in a way that preserves effects. It combines the capabilities
/// of `Functor` (mapping over elements) and `Foldable` (reducing to a single value).
///
/// The core operation of `Traversable` is `sequence`, which takes a structure
/// containing monadic/applicative values (`F<M<A>>`) and "flips" it inside out
/// to produce a monadic/applicative value containing the structure (`M<F<A>>`).
///
/// # Intuition & Analogy
///
/// Imagine you have a list of optional values (`Vec<Option<i32>>`). If any of the
/// options in the list are `None`, you might want the whole operation to fail and
/// just yield `None`. Otherwise, you want `Some` list of integers (`Option<Vec<i32>>`).
/// `sequence` achieves exactly this.
///
/// - `Vec<Option<A>>` -> `Option<Vec<A>>`
/// - `Vec<Result<A, E>>` -> `Result<Vec<A>, E>`
/// - `Option<Result<A, E>>` -> `Result<Option<A>, E>`
///
/// `Traversable` allows you to abstract over these kinds of transformations. It's
/// particularly useful for collecting errors, propagating "empty" states, or
/// accumulating results across collections of effectful computations.
///
/// # Laws (Informal)
///
/// `Traversable` laws are typically expressed in terms of `sequence` and `traverse`
/// (which can be defined in terms of `sequence` and `fmap`, or vice-versa).
///
/// 1.  **Naturality**: `t.sequence.map(f) == t.map(m.map(f)).sequence`
///     (Mapping over the result is the same as mapping inside the monadic value then sequencing).
/// 2.  **Identity**: `t.sequence == t.map(id).sequence`
///     (Sequencing a structure of identity monads is the structure itself).
/// 3.  **Composition**: `t.map(compose).sequence == t.sequence.sequence`
///     (Sequencing over a composite structure is equivalent to composing the sequenced results).
///
/// # Type Parameters
///
/// *   `F`: A Higher-Kinded Type (HKT) witness that represents the type constructor
///     of the traversable structure (e.g., `VecWitness`, `OptionWitness`).
///     This `F` must also be a `Functor` and `Foldable`.
pub trait Traversable<F: HKT>: Functor<F> + Foldable<F> {
    /// Transforms a structure containing applicative values (`F::Type<M::Type<A>>`)
    /// into an applicative value containing the structure (`M::Type<F::Type<A>>`).
    ///
    /// This operation essentially "flips" the outer structure with the inner applicative context.
    /// If any inner applicative value is in an "empty" or "failure" state, that state
    /// propagates to the outer applicative result. Otherwise, the values are collected
    /// into the structure wrapped by the applicative context.
    ///
    /// # Arguments
    ///
    /// *   `fa`: An instance of the traversable structure (`F::Type`) where each element
    ///     is wrapped in an applicative context (`M::Type`).
    ///
    /// # Returns
    ///
    /// An instance of the applicative context (`M::Type`) containing the original
    /// traversable structure (`F::Type`) with its elements unwrapped from their
    /// individual applicative contexts.
    ///
    /// # Type Parameters
    ///
    /// *   `A`: The type of the values contained within the innermost applicative context.
    /// *   `M`: The Higher-Kinded Type (HKT) witness for the inner applicative context
    ///     (e.g., `OptionWitness`, `ResultWitness<E>`). This `M` must implement `Applicative`.
    ///
    /// # Requirements
    ///
    /// *   `M: Applicative<M> + HKT`: The inner type `M` must be an `Applicative`
    ///     (which implies it is also a `Functor`) and an `HKT`.
    /// *   `A: Clone`: The values `A` must be clonable, as elements might be copied
    ///     during the sequencing process (e.g., when building a new collection).
    ///
    /// # Examples
    ///
    /// ```rust,ignore
    /// use deep_causality_haft::{Traversable, OptionWitness, VecWitness, HKT};
    ///
    /// // Flipping Vec<Option<i32>> to Option<Vec<i32>>
    /// let vec_opt = vec![Some(1), Some(2), Some(3)];
    /// let sequenced: Option<Vec<i32>> = VecWitness::sequence::<i32, OptionWitness>(vec_opt);
    /// assert_eq!(sequenced, Some(vec![1, 2, 3]));
    ///
    /// let vec_opt_with_none = vec![Some(1), None, Some(3)];
    /// let sequenced_none: Option<Vec<i32>> = VecWitness::sequence::<i32, OptionWitness>(vec_opt_with_none);
    /// assert_eq!(sequenced_none, None); // None propagates
    /// ```
    fn sequence<A, M>(fa: F::Type<M::Type<A>>) -> M::Type<F::Type<A>>
    where
        M: Applicative<M> + HKT,
        A: Clone + Satisfies<F::Constraint> + Satisfies<M::Constraint>,
        M::Type<A>: Satisfies<F::Constraint>,
        F::Type<A>: Satisfies<M::Constraint>;
}
