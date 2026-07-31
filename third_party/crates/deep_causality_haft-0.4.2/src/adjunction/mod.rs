/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT, Satisfies};

/// The `Adjunction` trait defines a pair of adjoint functors `L` (Left) and `R` (Right)
/// with an optional runtime `Context`.
///
/// # Category Theory
///
/// An **Adjunction** L ⊣ R exists between two categories C and D if there is a
/// natural isomorphism between the set of morphisms:
///
/// ```text
/// Hom_D(L(A), B) ≅ Hom_C(A, R(B))
/// ```
///
/// This is one of the most profound concepts in mathematics, generalizing the idea
/// of "opposites" or "duals". Examples include Free/Forgetful functors,
/// Currying/Uncurrying, and Quantifiers (∃ ⊣ const ⊣ ∀).
///
/// # Unified Design
///
/// This trait unifies the previous `Adjunction` and `BoundedAdjunction` traits.
/// The `Context` type parameter allows for runtime context (like Metric, Shape,
/// or Topology) that cannot be fully captured in the static type system.
///
/// # Mathematical Definition
///
/// The isomorphism is defined by two natural transformations:
/// - **Unit (η)**: id → R ∘ L
/// - **Counit (ε)**: L ∘ R → id
///
/// Satisfying the triangle identities:
/// 1. R(ε) ∘ η_R = id_R
/// 2. ε_L ∘ L(η) = id_L
///
/// # Use Cases
///
/// - **Conservation Laws**: In Discrete Exterior Calculus (DEC), the Boundary
///   Operator (∂) and Exterior Derivative (d) are adjoints:
///   `⟨dφ, J⟩ = ⟨φ, ∂J⟩`
/// - **Optimization**: Relating a constraint space (Primal) to a Lagrange
///   multiplier space (Dual).
///
/// # Type Parameters
///
/// - `L`: The left adjoint functor (HKT witness)
/// - `R`: The right adjoint functor (HKT witness)
/// - `Context`: Runtime context type (use `()` if no context needed)
pub trait Adjunction<L, R, Context>
where
    L: HKT,
    R: HKT,
{
    /// The Unit of the Adjunction: `A → R<L<A>>`
    ///
    /// Embeds a value into the Right-Left context.
    ///
    /// # Arguments
    ///
    /// - `ctx`: Runtime context for the operation
    /// - `a`: The value to embed
    ///
    /// # Returns
    ///
    /// The value embedded in the `R<L<_>>` structure.
    fn unit<A>(ctx: &Context, a: A) -> R::Type<L::Type<A>>
    where
        A: Satisfies<L::Constraint> + Satisfies<R::Constraint> + Clone,
        L::Type<A>: Satisfies<R::Constraint>;

    /// The Counit of the Adjunction: `L<R<B>> → B`
    ///
    /// Collapses the Left-Right context back to a value.
    ///
    /// # Arguments
    ///
    /// - `ctx`: Runtime context for the operation
    /// - `lrb`: The nested `L<R<B>>` structure to collapse
    ///
    /// # Returns
    ///
    /// The extracted value of type `B`.
    fn counit<B>(ctx: &Context, lrb: L::Type<R::Type<B>>) -> B
    where
        B: Satisfies<L::Constraint> + Satisfies<R::Constraint> + Clone,
        R::Type<B>: Satisfies<L::Constraint>;

    /// The Left Adjunct: `(L<A> → B) → (A → R<B>)`
    ///
    /// Transforms a function on the "Left" structure to a function on the "Right" structure.
    ///
    /// # Arguments
    ///
    /// - `ctx`: Runtime context for the operation
    /// - `a`: The input value
    /// - `f`: A function from `L<A>` to B
    ///
    /// # Returns
    ///
    /// The result of applying the transformed function, yielding `R<B>`.
    fn left_adjunct<A, B, Func>(ctx: &Context, a: A, f: Func) -> R::Type<B>
    where
        A: Satisfies<L::Constraint> + Satisfies<R::Constraint> + Clone,
        B: Satisfies<R::Constraint>,
        L::Type<A>: Satisfies<R::Constraint>,
        Func: Fn(L::Type<A>) -> B;

    /// The Right Adjunct: `(A → R<B>) → (L<A> → B)`
    ///
    /// Transforms a function on the "Right" structure to a function on the "Left" structure.
    ///
    /// # Arguments
    ///
    /// - `ctx`: Runtime context for the operation
    /// - `la`: The input value wrapped in L
    /// - `f`: A function from A to `R<B>`
    ///
    /// # Returns
    ///
    /// The result of applying the transformed function, yielding B.
    fn right_adjunct<A, B, Func>(ctx: &Context, la: L::Type<A>, f: Func) -> B
    where
        A: Satisfies<L::Constraint> + Clone,
        B: Satisfies<L::Constraint> + Satisfies<R::Constraint> + Clone,
        R::Type<B>: Satisfies<L::Constraint>,
        Func: FnMut(A) -> R::Type<B>;
}
