/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT2Unbound, Satisfies};

/// The `Bifunctor` trait allows mapping over both arguments of a type constructor `F<A, B>`.
///
/// # Category Theory
/// A **Bifunctor** is a functor from the product category $\mathcal{C} \times \mathcal{D}$ to $\mathcal{E}$.
/// It satisfies the functor laws for both arguments independently and simultaneously.
///
/// *   **Bimap**: $(A \to C) \to (B \to D) \to F(A, B) \to F(C, D)$
///
/// # Mathematical Definition
/// Let $B: \mathcal{C} \times \mathcal{D} \to \mathcal{E}$ be a bifunctor.
/// For any two morphisms $f: A \to C$ and $g: B \to D$, there exists a morphism
/// $B(f, g): B(A, B) \to B(C, D)$ such that:
/// 1.  $B(id_A, id_B) = id_{B(A, B)}$
/// 2.  $B(f' \circ f, g' \circ g) = B(f', g') \circ B(f, g)$
///
/// # Use Cases
/// *   **Result Handling**: Mapping both `Ok` and `Err` variants of a `Result<T, E>`.
/// *   **Systems Evolution**: Evolving a `System<Topology, Algebra>` where both components change type.
pub trait Bifunctor<F: HKT2Unbound> {
    /// Maps both types simultaneously.
    ///
    /// # Arguments
    /// * `fab`: The initial structure `F<A, B>`.
    /// * `f1`: Function to transform the first type `A -> C`.
    /// * `f2`: Function to transform the second type `B -> D`.
    fn bimap<A, B, C, D, F1, F2>(fab: F::Type<A, B>, f1: F1, f2: F2) -> F::Type<C, D>
    where
        A: Satisfies<F::Constraint>,
        B: Satisfies<F::Constraint>,
        C: Satisfies<F::Constraint>,
        D: Satisfies<F::Constraint>,
        F1: FnMut(A) -> C,
        F2: FnMut(B) -> D;

    /// Maps only the first type parameter.
    /// Equivalent to `bimap(f, id)`.
    fn first<A, B, C, F1>(fab: F::Type<A, B>, f1: F1) -> F::Type<C, B>
    where
        A: Satisfies<F::Constraint>,
        B: Satisfies<F::Constraint> + Clone,
        C: Satisfies<F::Constraint>,
        F1: FnMut(A) -> C,
    {
        Self::bimap(fab, f1, |b| b)
    }

    /// Maps only the second type parameter.
    /// Equivalent to `bimap(id, g)`.
    fn second<A, B, D, F2>(fab: F::Type<A, B>, f2: F2) -> F::Type<A, D>
    where
        A: Satisfies<F::Constraint> + Clone,
        B: Satisfies<F::Constraint>,
        D: Satisfies<F::Constraint>,
        F2: FnMut(B) -> D,
    {
        Self::bimap(fab, |a| a, f2)
    }
}
