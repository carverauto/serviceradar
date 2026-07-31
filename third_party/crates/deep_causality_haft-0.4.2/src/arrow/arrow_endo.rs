/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Arrow;

/// The value-level realization of the `Endomorphism` monoid, as a type extension: iteration of
/// an endo-arrow (an [`Arrow`] whose input and output type coincide).
///
/// The witness-level [`Endomorphism`](crate::Endomorphism) combinators iterate a `fn`-pointer
/// morphism. A stepper that captures `dt` and a rate field is not a `fn` pointer, so — exactly as
/// `arrow-strength` realized composition at the value level — these combinators iterate a
/// value-level endo-arrow instead. The three methods are the three integration modes: fixed
/// horizon, steady state, and integrate-until-event.
///
/// Blanket-implemented for every `Arrow<In = S, Out = S>`, so `Euler` / `Rk4` (and any other
/// endo-arrow) gain them for free.
pub trait EndoArrow<S>: Arrow<In = S, Out = S> {
    /// Apply the endo-arrow exactly `n` times — a fixed-horizon march.
    #[inline]
    fn iterate_n(&self, initial: S, n: usize) -> S {
        let mut state = initial;
        for _ in 0..n {
            state = self.run(state);
        }
        state
    }

    /// Apply until a fixpoint (the next state equals the current) or `max_steps` is reached.
    /// Returns the final state and `true` if a fixpoint was reached, `false` if the bound hit.
    #[inline]
    fn iterate_to_fixpoint(&self, initial: S, max_steps: usize) -> (S, bool)
    where
        S: Clone + PartialEq,
    {
        let mut state = initial;
        for _ in 0..max_steps {
            let next = self.run(state.clone());
            if next == state {
                return (next, true);
            }
            state = next;
        }
        (state, false)
    }

    /// Apply until `predicate` holds or `max_steps` is reached. The predicate is checked on the
    /// initial state first. Returns the final state and whether the predicate was met in time.
    #[inline]
    fn iterate_until<P>(&self, initial: S, mut predicate: P, max_steps: usize) -> (S, bool)
    where
        P: FnMut(&S) -> bool,
    {
        let mut state = initial;
        if predicate(&state) {
            return (state, true);
        }
        for _ in 0..max_steps {
            state = self.run(state);
            if predicate(&state) {
                return (state, true);
            }
        }
        (state, false)
    }
}

impl<S, A: Arrow<In = S, Out = S>> EndoArrow<S> for A {}
