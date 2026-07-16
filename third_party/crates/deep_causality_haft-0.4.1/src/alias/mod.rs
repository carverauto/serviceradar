/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Alias Traits for Intuitive Method Names.
//!
//! This module provides alias traits that wrap the core category-theoretic traits
//! with more intuitive, commonly-used method names. These aliases make the library
//! more accessible to developers who may not be familiar with functional programming
//! or category theory terminology.
//!
//! # Available Aliases
//!
//! | Alias Trait | Original Trait | Method Mappings |
//! |-------------|----------------|-----------------|
//! | [`AliasAdjunction`] | [`Adjunction`] | `integrate` → `left_adjunct`, `differentiate` → `right_adjunct` |
//! | [`AliasFunctor`] | [`Functor`] | `transform` → `fmap` |
//! | [`AliasMonad`] | [`Monad`] | `chain` → `bind`, `flatten` → `join` |
//! | [`AliasCoMonad`] | [`CoMonad`] | `observe` → `extract`, `propagate` → `extend` |
//! | [`AliasFoldable`] | [`Foldable`] | `reduce` → `fold` |
//! | [`AliasProfunctor`] | [`Profunctor`] | `adapt` → `dimap`, `preprocess` → `lmap`, `postprocess` → `rmap` |
//!
//! # Usage
//!
//! All aliases have blanket implementations, so any type implementing the original
//! trait automatically gets the alias methods. Simply import the alias trait:
//!
//! ```rust
//! use deep_causality_haft::{AliasFunctor, VecWitness};
//!
//! let v = vec![1, 2, 3];
//! let v_transformed = VecWitness::transform(v, |x| x * 2);
//! assert_eq!(v_transformed, vec![2, 4, 6]);
//! ```
//!
//! [`AliasAdjunction`]: alias_adjunction::AliasAdjunction
//! [`AliasFunctor`]: alias_functor::AliasFunctor
//! [`AliasMonad`]: alias_monad::AliasMonad
//! [`AliasCoMonad`]: alias_comonad::AliasCoMonad
//! [`AliasFoldable`]: alias_foldable::AliasFoldable
//! [`AliasProfunctor`]: alias_profunctor::AliasProfunctor
//! [`Adjunction`]: crate::Adjunction
//! [`Functor`]: crate::Functor
//! [`Monad`]: crate::Monad
//! [`CoMonad`]: crate::CoMonad
//! [`Foldable`]: crate::Foldable
//! [`Profunctor`]: crate::Profunctor

pub(crate) mod alias_adjunction;
pub(crate) mod alias_comonad;
pub(crate) mod alias_foldable;
pub(crate) mod alias_functor;
pub(crate) mod alias_monad;
pub(crate) mod alias_profunctor;
