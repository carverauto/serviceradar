/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT3Unbound, Satisfies};

/// The `ParametricMonad` (or Indexed Monad) trait allows for monadic computations where the
/// type of the underlying state can change at each step.
///
/// # Category Theory
/// An **Indexed Monad** is a generalization of a Monad. Instead of a single endofunctor $M: \mathcal{C} \to \mathcal{C}$,
/// we have a family of functors $M_{ij}: \mathcal{C} \to \mathcal{C}$ indexed by states $i, j$.
///
/// *   **Bind**: $M_{ij}(A) \to (A \to M_{jk}(B)) \to M_{ik}(B)$
///
/// # Mathematical Definition
/// It models a category where objects are states and morphisms are state transitions carrying a value.
/// The `ibind` operation composes these transitions: $(i \to j) \circ (j \to k) = (i \to k)$.
///
/// # Use Cases
/// *   **Phase Transitions**: Simulating a system evolving from `Fluid` -> `Gas` -> `Plasma`.
/// *   **Protocol State Machines**: Enforcing correct ordering of operations (e.g., `Unauthenticated` -> `Authenticated`).
/// *   **Topology Rewrites**: Changing the mesh type from `Triangular` to `Hexagonal` during a simulation step.
pub trait ParametricMonad<M: HKT3Unbound> {
    /// Injects a value into a computation that doesn't change the state type ($S \to S$).
    fn pure<S, A>(value: A) -> M::Type<S, S, A>
    where
        S: Satisfies<M::Constraint>,
        A: Satisfies<M::Constraint>;

    /// Indexed Bind: Chains computations where the state type evolves.
    ///
    /// # Arguments
    /// * `m`: The initial computation transitioning $S1 \to S2$.
    /// * `f`: A function taking the result $A$ and producing a new computation $S2 \to S3$.
    ///
    /// # Returns
    /// A new computation transitioning $S1 \to S3$.
    fn ibind<S1, S2, S3, A, B, F>(m: M::Type<S1, S2, A>, f: F) -> M::Type<S1, S3, B>
    where
        S1: Satisfies<M::Constraint>,
        S2: Satisfies<M::Constraint>,
        S3: Satisfies<M::Constraint>,
        A: Satisfies<M::Constraint>,
        B: Satisfies<M::Constraint>,
        F: FnMut(A) -> M::Type<S2, S3, B>;
}
