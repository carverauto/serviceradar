/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Adjunction, HKT, Satisfies};

/// Alias trait for `Adjunction` providing more intuitive method names.
///
/// # Motivation
///
/// The `Adjunction` trait uses category-theoretic terminology (`left_adjunct`, `right_adjunct`)
/// which may be unfamiliar to many developers. This alias trait provides common, intuitive
/// names that map to the underlying adjunction operations:
///
/// - `integrate` → `left_adjunct`: Transforms a function on the "Left" structure
///   to a function on the "Right" structure (analogous to integration in calculus).
/// - `differentiate` → `right_adjunct`: Transforms a function on the "Right" structure
///   to a function on the "Left" structure (analogous to differentiation in calculus).
///
/// # Example
///
/// ```ignore
/// use deep_causality_haft::AdjunctionAlias;
///
/// // Instead of:
/// // let result = MyType::left_adjunct(&ctx, value, |x| transform(x));
///
/// // You can use the more intuitive:
/// let result = MyType::integrate(&ctx, value, |x| transform(x));
/// ```
pub trait AliasAdjunction<L, R, Context>: Adjunction<L, R, Context>
where
    L: HKT,
    R: HKT,
{
    /// Alias for `left_adjunct`.
    ///
    /// Transforms a function on the "Left" structure to a function on the "Right" structure.
    /// This is analogous to integration in calculus, where we "accumulate" or "lift" values
    /// into a higher-level structure.
    ///
    /// See [`Adjunction::left_adjunct`] for full documentation.
    #[inline]
    fn integrate<A, B, Func>(ctx: &Context, a: A, f: Func) -> R::Type<B>
    where
        A: Satisfies<L::Constraint> + Satisfies<R::Constraint> + Clone,
        B: Satisfies<R::Constraint>,
        L::Type<A>: Satisfies<R::Constraint>,
        Func: Fn(L::Type<A>) -> B,
    {
        Self::left_adjunct(ctx, a, f)
    }

    /// Alias for `right_adjunct`.
    ///
    /// Transforms a function on the "Right" structure to a function on the "Left" structure.
    /// This is analogous to differentiation in calculus, where we "extract" or "project"
    /// values from a higher-level structure.
    ///
    /// See [`Adjunction::right_adjunct`] for full documentation.
    #[inline]
    fn differentiate<A, B, Func>(ctx: &Context, la: L::Type<A>, f: Func) -> B
    where
        A: Satisfies<L::Constraint> + Clone,
        B: Satisfies<L::Constraint> + Satisfies<R::Constraint> + Clone,
        R::Type<B>: Satisfies<L::Constraint>,
        Func: FnMut(A) -> R::Type<B>,
    {
        Self::right_adjunct(ctx, la, f)
    }
}

// Blanket implementation: any type that implements Adjunction automatically gets the alias.
impl<T, L, R, Context> AliasAdjunction<L, R, Context> for T
where
    T: Adjunction<L, R, Context>,
    L: HKT,
    R: HKT,
{
}
