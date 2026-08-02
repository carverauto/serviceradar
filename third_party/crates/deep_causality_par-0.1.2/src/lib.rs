/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Shared parallelism primitives for the DeepCausality workspace.
//!
//! Two items live here:
//!
//! * [`MaybeParallel`], the feature-conditional thread-safety marker that
//!   the `parallel` features of `deep_causality_topology`,
//!   `deep_causality_fft`, and their consumers share. Hosting it in one
//!   Tier-0 crate guarantees a single definition; Cargo feature
//!   unification on `deep_causality_par/parallel` keeps every crate in a
//!   build agreeing on whether the bound means `Send + Sync` or nothing.
//! * [`scoped_map`], the minimal in-house fork-join surface for few,
//!   long, data-independent tasks such as counterfactual branch fan-outs:
//!   an order-preserving parallel map over a slice on
//!   [`std::thread::scope`] threads under the `parallel` feature, a plain
//!   inline map without it. No thread pool, no external dependency.

mod functions;
pub mod traits;

pub use crate::functions::scoped_map::scoped_map;
pub use crate::traits::maybe_parallel::MaybeParallel;
