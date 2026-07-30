/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # The Cofree Comonad
//!
//! `Cofree<F, A>` is the **cofree comonad** on a functor `F` — the categorical dual of
//! [`Free`](crate::Free). Where `Free f a = Pure a | Suspend (f (Free f a))` is a coproduct
//! (an operation *tree terminated by pure leaves*), `Cofree` is the product
//!
//! ```text
//! Cofree f a = a :< f (Cofree f a)
//! ```
//!
//! — a value `head : A` paired with an `F`-structure of sub-trees `tail : f (Cofree f a)`. It is
//! the canonical carrier for **annotated / labelled trees**: every node carries a label and an
//! `F`-shaped collection of labelled children (Uustalu & Vene, *Comonadic Notions of Computation*,
//! ENTCS 203(5), 2008; Ghani, Uustalu & Vene, *Build, Augment, Destroy, Unfold*, APLAS 2004).
//!
//! - `extract (a :< _)   = a`                            (the counit ε, dual of `Free::pure`)
//! - `extend k w         = k w :< fmap (extend k) (tail w)`   (cobind, dual of `Free::bind`)
//! - `unfold c x         = let (a, fx) = c x in a :< fmap (unfold c) fx`  (the anamorphism, dual of
//!   `Free::fold`)
//!
//! The three comonad laws hold for **every** functor `F` (machine-checked in
//! `lean/DeepCausalityFormal/Haft/Cofree.lean`, dual to `FreeMonad.lean`, reusing `Comonad.lean`'s
//! statements; witnessed in `deep_causality_haft/tests/formalization_lean/cofree_tests.rs`).
//!
//! ## Finiteness
//!
//! In pure theory `Cofree f a` is coinductive (infinite). In strict Rust it is *finitely
//! constructible* only over functors that admit an **empty** shape — `Option`, `Vec`, a list
//! functor that bottoms out. That is exactly the annotated-tree use this type is for.
//! [`unfold`](Cofree::unfold) is the generator; it terminates iff the coalgebra's `F`-structure is
//! eventually empty.
//!
//! ## Rust encoding note (`Fn + Clone`)
//!
//! The inherent [`map`](Cofree::map) takes `Fn + Clone`, not the bare `FnMut` of the [`Functor`]
//! trait, for the same reason [`Free::map`](crate::Free::map) does: it threads the functor action
//! through **every** hole of the node while owning and moving through the tree, and a multi-hole
//! functor needs one copy of the closure per hole. This inherent surface is the ergonomic default.
//! [`extend`](Cofree::extend) and [`unfold`](Cofree::unfold) borrow their function argument, so —
//! unlike `Free::bind` — they need no `Clone` on it.
//!
//! [`CofreeWitness`] additionally implements the [`Functor`] and [`CoMonad`] **traits**: a
//! `Functor::fmap` *can* carry the trait's `FnMut` by threading a single `&mut f` through a
//! depth-first traversal (no per-hole clone is needed when the tree is owned and holes are visited in
//! sequence), and it agrees with the inherent `map` for pure functions; `CoMonad` is the
//! by-reference `extract`/`extend` twin, which needs [`CloneFunctor`] to rebuild a `Cofree` from a
//! borrow. These trait instances are provided by the `haft-clone-functor` change alongside
//! `Cofree`'s `Clone`.

use crate::{
    CloneFunctor, CoMonad, DebugFunctor, EqFunctor, Functor, HKT, NoConstraint, Satisfies,
};
use alloc::boxed::Box;
use core::fmt;
use core::marker::PhantomData;

/// The cofree comonad on a functor `F`: `head :< f (Cofree f a)`.
///
/// `F` is an [`HKT`] witness that is a [`Functor`] over the unconstrained (`NoConstraint`) universe.
/// `Cofree<F, A>` is an annotated tree: every node carries a `head: A` label and an `F`-structure of
/// child sub-trees. Fields are private; use [`new`](Cofree::new) / [`head`](Cofree::head) /
/// [`tail`](Cofree::tail) / [`into_parts`](Cofree::into_parts).
pub struct Cofree<F, A>
where
    F: HKT<Constraint = NoConstraint>,
{
    head: A,
    tail: F::Type<Box<Cofree<F, A>>>,
}

impl<F, A> Cofree<F, A>
where
    F: HKT<Constraint = NoConstraint>,
{
    /// Construct a node from its label and its `F`-structure of sub-trees.
    #[inline]
    pub fn new(head: A, tail: F::Type<Box<Cofree<F, A>>>) -> Self {
        Cofree { head, tail }
    }

    /// The label at this node.
    #[inline]
    pub fn head(&self) -> &A {
        &self.head
    }

    /// The `F`-structure of child sub-trees at this node.
    #[inline]
    pub fn tail(&self) -> &F::Type<Box<Cofree<F, A>>> {
        &self.tail
    }

    /// Decompose the node into its label and its `F`-structure of sub-trees.
    #[inline]
    pub fn into_parts(self) -> (A, F::Type<Box<Cofree<F, A>>>) {
        (self.head, self.tail)
    }

    /// `extract`: the counit ε — read the label at this node (dual of `Free::pure`).
    #[inline]
    pub fn extract(&self) -> A
    where
        A: Clone,
    {
        self.head.clone()
    }
}

impl<F, A> Cofree<F, A>
where
    F: HKT<Constraint = NoConstraint> + Functor<F>,
{
    /// The functor action, derived like `Free::map` (`Fn + Clone`, one copy per hole): relabel every
    /// node by `f`, preserving the tree shape.
    pub fn map<B, Fun>(self, f: Fun) -> Cofree<F, B>
    where
        Fun: Fn(A) -> B + Clone,
    {
        let head = f(self.head);
        let g = f.clone();
        let tail = F::fmap(self.tail, move |boxed: Box<Cofree<F, A>>| {
            Box::new((*boxed).map(g.clone()))
        });
        Cofree { head, tail }
    }

    /// `extend`: cobind, the dual of `Free::bind`. Refocus every node on the observation `k` of its
    /// whole sub-tree — `extend k w = k(w) :< fmap (extend k) (tail w)`.
    ///
    /// `k` is borrowed and threaded through every hole, so no `Clone` on it is required.
    pub fn extend<B, K>(self, k: &K) -> Cofree<F, B>
    where
        K: Fn(&Cofree<F, A>) -> B,
    {
        let head = k(&self);
        let tail = F::fmap(self.tail, |boxed: Box<Cofree<F, A>>| {
            Box::new((*boxed).extend(k))
        });
        Cofree { head, tail }
    }

    /// `unfold`: the anamorphism, dual of `Free::fold`. Grow a tree from a `seed` and a `coalg`ebra
    /// that produces, at each step, this node's label and the `F`-structure of child seeds —
    /// `unfold c x = let (a, fx) = c x in a :< fmap (unfold c) fx`.
    ///
    /// Terminates iff `coalg`'s `F`-structure is eventually empty (see the module-level finiteness
    /// note). `coalg` is borrowed and threaded through every hole.
    pub fn unfold<X, C>(seed: X, coalg: &C) -> Cofree<F, A>
    where
        C: Fn(X) -> (A, F::Type<X>),
    {
        let (a, fx) = coalg(seed);
        let tail = F::fmap(fx, |x: X| Box::new(Cofree::unfold(x, coalg)));
        Cofree { head: a, tail }
    }

    /// `duplicate`: replace every node's label with the whole sub-tree focused at that node —
    /// `duplicate = extend (|w| w.clone())`, the comonadic `duplicate` (`extend id`).
    ///
    /// Requires the tree to be cloneable (`F: CloneFunctor`, `A: Clone`), which is why it is provided
    /// only now that `Cofree<F, A>: Clone` exists — dual to `Free`'s `join` needing no cloning. The
    /// result is `Cofree<F, Cofree<F, A>>`: the counit `extract` of each position recovers the
    /// sub-tree it was focused on.
    pub fn duplicate(self) -> Cofree<F, Cofree<F, A>>
    where
        F: CloneFunctor,
        A: Clone,
    {
        self.extend(&|w| w.clone())
    }
}

// Opt-in `PartialEq`/`Eq`/`Debug`, routed through the functor's `EqFunctor`/`DebugFunctor` — the
// same cycle-free mechanism as `free_instances.rs` (see `EqFunctor` for why a projection bound
// would overflow).

/// Structural equality: equal labels and equal `F`-structures of sub-trees (compared through the
/// functor's `eq_type`). Terminates because the recursive obligation `Box<Cofree<F, A>>: PartialEq`
/// discharges against this impl.
impl<F, A> PartialEq for Cofree<F, A>
where
    F: EqFunctor,
    A: PartialEq,
{
    fn eq(&self, other: &Self) -> bool {
        self.head == other.head && F::eq_type(&self.tail, &other.tail)
    }
}

/// `Eq` is the marker upgrade of the structural `PartialEq`.
impl<F, A> Eq for Cofree<F, A>
where
    F: EqFunctor,
    A: Eq,
{
}

/// `Debug` renders `Cofree { head, tail }`, formatting the `F`-structure through the functor's
/// `fmt_type`.
impl<F, A> fmt::Debug for Cofree<F, A>
where
    F: DebugFunctor,
    A: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Cofree { head: ")?;
        fmt::Debug::fmt(&self.head, f)?;
        f.write_str(", tail: ")?;
        F::fmt_type(&self.tail, f)?;
        f.write_str(" }")
    }
}

/// Structural clone: clone the `head` label and the `F`-structure of sub-trees through the functor's
/// `clone_type`. Terminates because the recursive obligation `Box<Cofree<F, A>>: Clone` discharges
/// against this impl (the same cycle-free mechanism as `PartialEq`).
impl<F, A> Clone for Cofree<F, A>
where
    F: CloneFunctor,
    A: Clone,
{
    fn clone(&self) -> Self {
        Cofree {
            head: self.head.clone(),
            tail: F::clone_type(&self.tail),
        }
    }
}

/// The [`HKT`] witness for the cofree comonad over the functor `F` (dual of
/// [`FreeWitness`](crate::FreeWitness)).
pub struct CofreeWitness<F>(PhantomData<F>);

impl<F> HKT for CofreeWitness<F>
where
    F: HKT<Constraint = NoConstraint>,
{
    type Constraint = NoConstraint;
    type Type<T> = Cofree<F, T>;
}

/// The functor action on `Cofree` as the `Functor` **trait** (the supertrait `CoMonad` requires),
/// distinct from the inherent [`Cofree::map`]. It relabels every node by `f`, preserving tree shape.
///
/// The trait's `FnMut` — which the inherent `map`'s `Fn + Clone` was introduced to avoid — is
/// carried here by consuming the tree and threading a single `&mut f` through a depth-first
/// traversal: `Free`-style per-hole cloning of the closure is unnecessary when the tree is owned and
/// the holes are visited in sequence. For a pure `f` the result is identical to the inherent `map`.
impl<F> Functor<CofreeWitness<F>> for CofreeWitness<F>
where
    F: HKT<Constraint = NoConstraint> + Functor<F>,
{
    fn fmap<A, B, Func>(m_a: Cofree<F, A>, mut f: Func) -> Cofree<F, B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        fn go<F, A, B, Func>(c: Cofree<F, A>, f: &mut Func) -> Cofree<F, B>
        where
            F: HKT<Constraint = NoConstraint> + Functor<F>,
            Func: FnMut(A) -> B,
        {
            let (head, tail) = c.into_parts();
            let new_head = f(head);
            let new_tail = F::fmap(tail, |boxed: Box<Cofree<F, A>>| Box::new(go(*boxed, f)));
            Cofree::new(new_head, new_tail)
        }
        go(m_a, &mut f)
    }
}

/// The cofree comonad's `CoMonad` **trait** instance, the by-reference twin of the inherent
/// by-value [`Cofree::extract`] / [`Cofree::extend`]. `extend` rebuilds the tree from a borrow, which
/// is why it requires `F: CloneFunctor` (to clone each node's `F`-structure of children before
/// mapping into it) — exactly the capability [`Cofree::duplicate`] needs. `k` is threaded by
/// `&mut` through the depth-first traversal, so no `Clone` on it is required.
impl<F> CoMonad<CofreeWitness<F>> for CofreeWitness<F>
where
    F: HKT<Constraint = NoConstraint> + Functor<F> + CloneFunctor,
{
    fn extract<A>(fa: &Cofree<F, A>) -> A
    where
        A: Satisfies<NoConstraint> + Clone,
    {
        fa.head().clone()
    }

    fn extend<A, B, Func>(fa: &Cofree<F, A>, mut f: Func) -> Cofree<F, B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        Func: FnMut(&Cofree<F, A>) -> B,
    {
        fn go<F, A, B, Func>(fa: &Cofree<F, A>, f: &mut Func) -> Cofree<F, B>
        where
            F: HKT<Constraint = NoConstraint> + Functor<F> + CloneFunctor,
            A: Clone,
            Func: FnMut(&Cofree<F, A>) -> B,
        {
            let head = f(fa);
            // Clone the children's `F`-structure so it can be consumed by `F::fmap`; the borrow
            // `fa` cannot be moved. `clone_type` needs `Box<Cofree<F, A>>: Clone`, satisfied by
            // `Cofree<F, A>: Clone` (`F: CloneFunctor`, `A: Clone`).
            let owned: F::Type<Box<Cofree<F, A>>> = F::clone_type(fa.tail());
            let tail = F::fmap(owned, |boxed: Box<Cofree<F, A>>| Box::new(go(&boxed, f)));
            Cofree::new(head, tail)
        }
        go(fa, &mut f)
    }
}
