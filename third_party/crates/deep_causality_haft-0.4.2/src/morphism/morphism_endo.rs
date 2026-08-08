/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT2Unbound, Morphism, Satisfies};

/// The type-preserving fragment of [`Morphism`]: arrows `T → T`.
///
/// # Category Theory
///
/// An endomorphism is a morphism from a type back to itself. `End(T)` is a **monoid**
/// under composition (identity is the unit, composition is associative), which licenses
/// folding a list of state-transitions into one. Composition itself lives with the
/// strength stage (see [`Morphism`]); what this trait adds now is the family of bounded
/// iteration/fixpoint combinators that repeatedly apply a `T → T` arrow.
///
/// It is a marker with a blanket implementation over any [`Morphism`] witness, so every
/// morphism family automatically gains the combinators on its type-preserving arrows.
///
/// # Bounded, not unbounded
///
/// Every combinator that can fail to converge takes an explicit `max_steps` and reports,
/// via the returned `bool`, whether convergence was actually reached — rather than looping
/// without bound. This is the safe shape for the BRCD Meek-rule fixpoint and effect
/// propagation: a rule set that does not converge returns "not converged" instead of
/// hanging.
pub trait Endomorphism<P: HKT2Unbound>: Morphism<P> {
    /// Apply `arrow` to `x` exactly `n` times.
    fn iterate_n<T>(arrow: &P::Type<T, T>, x: T, n: usize) -> T
    where
        T: Satisfies<P::Constraint>,
    {
        let mut acc = x;
        for _ in 0..n {
            acc = Self::apply(arrow, acc);
        }
        acc
    }

    /// Apply `arrow` until a fixpoint is reached (the next iterate equals the current
    /// value) or `max_steps` applications have occurred.
    ///
    /// Returns the final value and `true` if a fixpoint was reached, `false` if the step
    /// bound was hit first.
    fn iterate_to_fixpoint<T>(arrow: &P::Type<T, T>, x: T, max_steps: usize) -> (T, bool)
    where
        T: Satisfies<P::Constraint> + Clone + PartialEq,
    {
        let mut acc = x;
        for _ in 0..max_steps {
            let next = Self::apply(arrow, acc.clone());
            if next == acc {
                return (next, true);
            }
            acc = next;
        }
        (acc, false)
    }

    /// Apply `arrow` until `predicate(&x)` holds or `max_steps` applications have occurred.
    ///
    /// The predicate is checked on the initial value before any application. Returns the
    /// final value and `true` if the predicate was met, `false` if the step bound was hit
    /// first.
    fn iterate_until<T, Pred>(
        arrow: &P::Type<T, T>,
        x: T,
        mut predicate: Pred,
        max_steps: usize,
    ) -> (T, bool)
    where
        T: Satisfies<P::Constraint>,
        Pred: FnMut(&T) -> bool,
    {
        let mut acc = x;
        if predicate(&acc) {
            return (acc, true);
        }
        for _ in 0..max_steps {
            acc = Self::apply(arrow, acc);
            if predicate(&acc) {
                return (acc, true);
            }
        }
        (acc, false)
    }
}

/// Every [`Morphism`] witness is an [`Endomorphism`] on its type-preserving arrows.
impl<P: HKT2Unbound, M: Morphism<P>> Endomorphism<P> for M {}
