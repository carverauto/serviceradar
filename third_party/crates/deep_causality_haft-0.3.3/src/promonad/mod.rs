/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT3Unbound, Satisfies};

/// The `Promonad` trait models the "fusion" or "interaction" of two contexts to produce a third.
///
/// # Category Theory
/// This is related to **Monoidal Functors** and **Day Convolution**. It defines a mapping from the
/// tensor product of two functors to a third functor:
/// $$ F(A) \otimes G(B) \to H(A \otimes B) $$
///
/// In our Arity-3 definition $P<A, B, C>$, it acts as a "Pre-Arrow" or a specialized profunctor
/// mapping $(A, B) \to C$.
///
/// # Use Cases
/// *   **Tensor Contraction**: Merging a Vector $u$ and a Dual Vector $v^*$ to produce a Scalar.
/// *   **Quantum Entanglement**: Combining Qubit A and Qubit B into an Entangled Pair C.
/// *   **Force Calculation**: Combining Current $J$ and Magnetic Field $B$ to produce Force $F$.
pub trait Promonad<P: HKT3Unbound> {
    /// Merges two contexts into a third.
    ///
    /// # Arguments
    /// * `pa`: The first context (Input A).
    /// * `pb`: The second context (Input B).
    /// * `f`: A function to combine the inner values $A$ and $B$ into $C$.
    fn merge<A, B, C, F>(
        pa: P::Type<A, A, A>, // Simplified signature for demonstration
        pb: P::Type<B, B, B>,
        f: F,
    ) -> P::Type<C, C, C>
    where
        A: Satisfies<P::Constraint>,
        B: Satisfies<P::Constraint>,
        C: Satisfies<P::Constraint>,
        F: FnMut(A, B) -> C;

    /// Fusion: Directly combines two raw inputs into the interaction context.
    fn fuse<A, B, C>(input_a: A, input_b: B) -> P::Type<A, B, C>
    where
        A: Satisfies<P::Constraint>,
        B: Satisfies<P::Constraint>,
        C: Satisfies<P::Constraint>;
}
