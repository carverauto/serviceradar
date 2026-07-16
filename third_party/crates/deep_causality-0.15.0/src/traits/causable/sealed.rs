/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The seal: the causal trait surface is **closed at the three causaloid forms**.
//!
//! `CausaloidType` is closed at exactly `Singleton` / `Collection` / `Graph` — a deliberate design
//! decision (`openspec/notes/causal-algebra/algebraic-causaloid-assumptions.md` #11a, DECIDED
//! 2026-07-09). The enum is closed by Rust semantics; this sealed supertrait closes the *trait*
//! surface too, so no downstream crate can introduce a de-facto fourth causal form by implementing
//! `Causable` / `MonadicCausable` / `StatefulMonadicCausable` for a new type.
//!
//! Consequence for the formalization: the signature functor `F` the causaloid catamorphism folds
//! over is **fixed**, giving the `evaluate`-uniqueness argument its closed-world premise
//! (`openspec/notes/causal-algebra/causaloid-formalization-roadmap.md`, Stage 5). Extension happens
//! on the **carrier** (verdict → probabilistic → operator-valued) and **wiring-generator**
//! (`∇`, `⊕`) axes over the *same* three forms — never by a new form
//! (`openspec/notes/quantum/full-stack.md` §9).
//!
//! This module is `pub(crate)`: the `Sealed` trait is nameable inside `deep_causality` (so the
//! supertrait bounds and the one impl resolve) and unnameable outside it (so it cannot be
//! implemented downstream) — the standard sealed-trait pattern.

/// Implemented only for `Causaloid<I, O, PS, C>` — the single carrier of all three causal forms.
pub trait Sealed {}
