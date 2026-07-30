/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Feature-conditional thread-safety alias.
//!
//! Parallel code paths (the per-cell DEC operator loops in
//! `deep_causality_topology`, the batched 1-D transforms in
//! `deep_causality_fft`) fan out over Rayon when their `parallel`
//! features are enabled, which requires the scalar to cross threads.
//! This alias trait expresses that requirement without forcing
//! `Send + Sync` on serial builds:
//!
//! - **`parallel` on**: `MaybeParallel ≡ Send + Sync` (blanket-implemented
//!   for every such type — all workspace scalars qualify).
//! - **`parallel` off**: `MaybeParallel` is empty and blanket-implemented
//!   for every type, so the bound is vacuous and the public API is
//!   unchanged.
//!
//! Bound additions of the form `R: … + MaybeParallel` on impl blocks are
//! therefore invisible to serial consumers and exactly the Rayon
//! requirement for parallel ones. Downstream crates forward their own
//! `parallel` feature to `deep_causality_par/parallel`, so feature
//! unification keeps the single definition consistent across a build.

/// Thread-safety requirement of feature-gated parallel loops; vacuous
/// without the `parallel` feature. See the module doc.
#[cfg(feature = "parallel")]
pub trait MaybeParallel: Send + Sync {}

#[cfg(feature = "parallel")]
impl<T: Send + Sync + ?Sized> MaybeParallel for T {}

/// Thread-safety requirement of feature-gated parallel loops; vacuous
/// without the `parallel` feature. See the module doc.
#[cfg(not(feature = "parallel"))]
pub trait MaybeParallel {}

#[cfg(not(feature = "parallel"))]
impl<T: ?Sized> MaybeParallel for T {}
