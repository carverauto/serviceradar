/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The `deep_causality_haft` crate provides foundational traits and utilities for
//! implementing Higher-Kinded Types (HKTs) and functional programming patterns
//! (Functor, Applicative, Monad, Foldable) in Rust.
//!
//! This crate is a core component of the `deep_causality` project, enabling
//! the construction of flexible and robust type-encoded effect systems.
//!
//! # Core Concepts
//!
//! *   **Higher-Kinded Types (HKTs)**: Abstractions over type constructors (e.g., `Option<T>`, `Vec<T>`).
//!     This allows writing generic code that works across different container types.
//! *   **Functor**: Defines the `fmap` operation for mapping a function over a type constructor.
//! *   **Applicative**: Extends `Functor` with `pure` (to lift values) and `apply` (to apply
//!     functions within a context).
//! *   **Monad**: Provides the `bind` operation for sequencing computations that produce
//!     effectful values.
//! *   **Foldable**: Defines the `fold` operation for reducing a data structure to a single value.
//! *   **Type-Encoded Effect Systems**: A mechanism to explicitly track and manage side-effects
//!     (like errors, logging, counters) using Rust's type system, ensuring compile-time verification.
//!
//! # Modules
//!
//! *   `core`: Core HKT definitions and machinery.
//! *   `algebra`: Algebraic traits (Functor, Monad, etc.).
//! *   `effect_system`: Type-encoded effect system traits.
//! *   `extensions`: Concrete HKT witness implementations for standard Rust types.
//! *   `utils_tests`: Internal utilities and test-specific effect types.
//!
//! # Usage
//!
//! This crate is primarily intended for internal use within the `deep_causality` project
//! to build its core abstractions. However, the traits and concepts can be generally applied
//! to other Rust projects requiring advanced functional programming patterns and effect management.
//!
#![cfg_attr(not(feature = "std"), no_std)]

#[cfg(feature = "alloc")]
extern crate alloc;

// Module Declarations
pub(crate) mod adjunction;
mod alias;
pub(crate) mod applicative;
mod arrow;
pub(crate) mod category;
pub(crate) mod cybernetic_loop;
pub(crate) mod effect_system;
pub(crate) mod either;
pub(crate) mod extensions;
pub(crate) mod foldable;
pub(crate) mod functor;
pub(crate) mod hkt;
pub(crate) mod io;
pub mod iso;
pub(crate) mod monad;
pub(crate) mod monoidal;
pub(crate) mod morphism;
pub(crate) mod natural_transformation;
pub(crate) mod pure;
pub(crate) mod riemann_map;
pub(crate) mod traversable;
pub mod utils_tests;
// ============================================================================
// Re-exports
// ============================================================================

// Aliases
pub use alias::alias_adjunction::AliasAdjunction;
pub use alias::alias_comonad::AliasCoMonad;
pub use alias::alias_foldable::AliasFoldable;
pub use alias::alias_functor::AliasFunctor;
pub use alias::alias_monad::AliasMonad;
pub use alias::alias_profunctor::AliasProfunctor;
// Arrow algebra (value-level strong category: composition + the monoidal product `⊗`, the
// coproduct/choice fragment `⊕` (ArrowChoice), + builder)
pub use crate::arrow::{
    Arrow, ArrowBuilder, Choice, Compose, EndoArrow, Fanin, Fanout, First, Id, Left, Lift, Right,
    Second, Split, arrow,
};
// Reified free Arrow: the typed-builder façade over the erased core (needs `alloc`, like `Free`)
#[cfg(feature = "alloc")]
pub use crate::arrow::{ArrowCore, ArrowTerm, ArrowVal};

// Category (named identity + composition; the Kleisli category of a monad, and the function category)
pub use crate::category::{Category, Fun, Kleisli};

// Symmetric-monoidal PROP (copy comonoid Δ/ε, merge monoid ∇/η, symmetry σ)
pub use crate::monoidal::SymMonoidal;

// Natural transformations (the morphism between functors; the naturality square)
pub use crate::natural_transformation::NaturalTransformation;
#[cfg(feature = "alloc")]
pub use crate::natural_transformation::OptionToVec;

// Either (the choice sum)
pub use crate::either::Either;

// IO effect (the lazy IO monad — value-level, no dyn, the Arrow twin)
pub use crate::io::{
    IoAction, IoAndThen, IoFail, IoMap, IoMapErr, IoPure, fail as io_fail, pure as io_pure,
};

// Isomorphism
pub use crate::iso::{NaturalIso, NaturalIso2, NaturalIso3, NaturalIso4, NaturalIso5};

// HKT
pub use crate::hkt::{HKT, HKT2, HKT3, HKT4, HKT5, Satisfies};
pub use crate::hkt::{HKT2Unbound, HKT3Unbound, HKT4Unbound, HKT5Unbound, HKT6Unbound};
pub use crate::hkt::{NoConstraint, Placeholder};

// Traits
pub use crate::adjunction::Adjunction;
pub use crate::applicative::Applicative;
pub use crate::cybernetic_loop::CyberneticLoop;
pub use crate::foldable::Foldable;
pub use crate::functor::bifunctor::Bifunctor;
pub use crate::functor::clone_functor::CloneFunctor;
pub use crate::functor::debug_functor::DebugFunctor;
pub use crate::functor::eq_functor::EqFunctor;
pub use crate::functor::functor_base::Functor;
pub use crate::functor::profunctor::Profunctor;
pub use crate::monad::Monad;
#[cfg(feature = "alloc")]
pub use crate::monad::cofree_comonad::{Cofree, CofreeWitness};
pub use crate::monad::comonad::CoMonad;
#[cfg(feature = "alloc")]
pub use crate::monad::free_monad::{Free, FreeWitness};
pub use crate::monad::monoidal_merge::MonoidalMerge;
pub use crate::monad::parametric_monad::ParametricMonad;
pub use crate::morphism::morphism_base::{FnMorphism, Morphism};
pub use crate::morphism::morphism_endo::Endomorphism;
pub use crate::pure::Pure;
pub use crate::riemann_map::RiemannMap;
pub use crate::traversable::Traversable;

// Effect System Traits
pub use crate::effect_system::effect::{Effect3, Effect4, Effect5};
pub use crate::effect_system::effect_log::{LogAddEntry, LogAppend, LogEffect, LogSize};
pub use crate::effect_system::effect_unbound::{Effect3Unbound, Effect4Unbound, Effect5Unbound};
pub use crate::effect_system::monad_effect::{MonadEffect3, MonadEffect4, MonadEffect5};
pub use crate::effect_system::monad_effect_unbound::{
    MonadEffect3Unbound, MonadEffect4Unbound, MonadEffect5Unbound,
};

// Functional Extensions (Witnesses Types)
#[cfg(feature = "alloc")]
pub use crate::extensions::func_fold_b_tree_map_ext::BTreeMapWitness;
#[cfg(feature = "std")]
pub use crate::extensions::func_fold_hash_map_ext::HashMapWitness;
#[cfg(feature = "alloc")]
pub use crate::extensions::func_fold_vec_deque_ext::VecDequeWitness;
#[cfg(feature = "alloc")]
pub use crate::extensions::hkt_box_ext::BoxWitness;
#[cfg(feature = "alloc")]
pub use crate::extensions::hkt_linked_list_ext::LinkedListWitness;
pub use crate::extensions::hkt_option_ext::OptionWitness;
pub use crate::extensions::hkt_result_ext::{ResultUnboundWitness, ResultWitness};
pub use crate::extensions::hkt_tuple_ext::{Tuple2Witness, Tuple3Witness};
#[cfg(feature = "alloc")]
pub use crate::extensions::hkt_vec_ext::VecWitness;
