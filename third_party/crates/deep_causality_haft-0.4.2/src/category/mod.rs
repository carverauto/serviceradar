/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT, Monad, NoConstraint, Pure};
use core::marker::PhantomData;

/// A **category**: an identity morphism on every object and associative composition of compatible
/// morphisms (Mac Lane, *Categories for the Working Mathematician*, §I.1).
///
/// This is the witness encoding used throughout `deep_causality_haft`: `Self` is a zero-sized
/// witness naming a category, and a morphism `A → B` is a function `A -> Self::Hom<B>`, where
/// `Hom<B>` wraps the codomain — the identity functor for the plain function category [`Fun`], and
/// `M::Type<B>` for the [`Kleisli`] category of a monad `M`. Composition and identity are the two
/// category operations; the category axioms hold **extensionally** on the produced morphisms.
///
/// # Laws
///
/// For all composable `f`, `g`, `h`:
///
/// 1. **Left identity**: `compose(id(), g) = g`.
/// 2. **Right identity**: `compose(f, id()) = f`.
/// 3. **Associativity**: `compose(compose(f, g), h) = compose(f, compose(g, h))`.
///
/// Machine-checked in `lean/DeepCausalityFormal/Haft/Category.lean` (the function category) and
/// `lean/DeepCausalityFormal/Haft/Kleisli.lean` (the Kleisli category, reduced to the monad laws).
pub trait Category {
    /// The codomain wrapper of a morphism into `B`: a morphism `A → B` is an `impl Fn(A) -> Hom<B>`.
    type Hom<B>;

    /// The identity morphism on `A` (`id: A → A`).
    ///
    /// The returned morphism is `Clone` so it can itself be composed further.
    fn id<A>() -> impl Fn(A) -> Self::Hom<A> + Clone;

    /// Sequential composition: `f: A → B` then `g: B → C`, yielding `A → C`.
    ///
    /// Morphisms are `Clone` (composition captures them) so composites compose further.
    fn compose<A, B, C>(
        f: impl Fn(A) -> Self::Hom<B> + Clone,
        g: impl Fn(B) -> Self::Hom<C> + Clone,
    ) -> impl Fn(A) -> Self::Hom<C> + Clone;
}

/// The **category of functions** `Fun`: `Hom<B> = B`, identity is `|a| a`, composition is `g ∘ f`.
///
/// This is the semantic category the value-level [`Arrow`](crate::Arrow) runs in: an `Arrow`
/// `a: A → B` is the `Fun` morphism `move |x| a.run(x)`, and the `Arrow` combinators
/// (`Id`/`Compose`) are the identity and composition of this category — the category whose laws are
/// proved in `lean/DeepCausalityFormal/Haft/Arrow.lean` (`haft.arrow.category_laws`).
pub struct Fun;

impl Category for Fun {
    type Hom<B> = B;

    #[inline]
    fn id<A>() -> impl Fn(A) -> A + Clone {
        |a| a
    }

    #[inline]
    fn compose<A, B, C>(
        f: impl Fn(A) -> B + Clone,
        g: impl Fn(B) -> C + Clone,
    ) -> impl Fn(A) -> C + Clone {
        move |a| g(f(a))
    }
}

/// The **Kleisli category** of a monad `M` (Mac Lane §VI.5; Moggi, *Notions of Computation and
/// Monads*, 1991): `Hom<B> = M::Type<B>`, identity is `pure`, and composition is `bind`
/// (`compose(f, g)(a) = bind(f(a), g)`, the Kleisli arrow `>=>`).
///
/// This is the typed semantic codomain the free-Arrow interpreter targets. Its category laws reduce
/// to the monad laws (`haft.monad.*`): left identity to `bind(pure a, g) = g a`, right identity to
/// `bind(m, pure) = m`, associativity to the monad associativity law.
///
/// SCOPING: `Kleisli` is a `Category` for monads whose HKT `Constraint` is [`NoConstraint`] (the
/// unconstrained monads — `Option`, `Result`, `Vec`, and the effect monad). This keeps every object
/// type an admissible object without threading a per-category object bound; constrained monads
/// (e.g. `CausalTensor`) are out of scope for this categorical substrate.
pub struct Kleisli<M>(PhantomData<M>);

impl<M> Category for Kleisli<M>
where
    M: Monad<M> + HKT<Constraint = NoConstraint>,
{
    type Hom<B> = M::Type<B>;

    #[inline]
    fn id<A>() -> impl Fn(A) -> M::Type<A> + Clone {
        |a| <M as Pure<M>>::pure(a)
    }

    #[inline]
    fn compose<A, B, C>(
        f: impl Fn(A) -> M::Type<B> + Clone,
        g: impl Fn(B) -> M::Type<C> + Clone,
    ) -> impl Fn(A) -> M::Type<C> + Clone {
        move |a| <M as Monad<M>>::bind(f(a), g.clone())
    }
}
