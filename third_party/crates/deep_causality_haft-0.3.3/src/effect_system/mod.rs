/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Type-Encoded Effect Systems.
//!
//! This module provides the infrastructure for building robust, type-safe effect systems in Rust.
//! Unlike dynamic effect handlers, these traits encode side-effects (like Errors, Logs, State, Traces)
//! directly into the type signature, ensuring compile-time verification of effect handling.
//!
//! # Core Concepts
//!
//! *   **Effect Witness**: A type that implements `Effect*` traits. It acts as a bridge, fixing specific
//!     types (e.g., `Error = String`) for a generic HKT.
//! *   **MonadEffect**: Extends the standard `Monad` with capabilities specific to the effect system,
//!     such as `lift_effect` (to inject side effects) or specialized `bind` operations.
//! *   **Arity**: The number of type parameters managed by the effect system.
//!     *   **Arity 3**: Value + 2 Effects (e.g., `Result<T, E>` + Log).
//!     *   **Arity 4**: Value + 3 Effects (e.g., `Result` + Log + Counter).
//!     *   **Arity 5**: Value + 4 Effects (e.g., `Result` + Log + Counter + Trace).
//!
//! # Fixed vs. Unbound Effects
//!
//! ## Fixed Effects (`Effect3`, `Effect4`, `Effect5`)
//! In a standard effect system, the side-effect types are fixed for the duration of the computation.
//! For example, an `Effect3` might fix `Fixed1 = String` (Error) and `Fixed2 = Vec<String>` (Log).
//! The `Monad` implementation works over the remaining free parameter (the Value).
//!
//! ## Unbound / Parametric Effects (`Effect*Unbound`)
//! These traits support **Parametric Monads** (Indexed Monads). They allow the type of a side-effect
//! (specifically the State or Counter) to *change* during the computation.
//!
//! *   **Type-State Pattern**: A protocol can transition from `State<Uninit>` to `State<Init>`.
//! *   **Reusability**: Allows defining effect logic without hardcoding the concrete effect types immediately.
//!
//! # Module Contents
//!
//! *   [`effect`]: Traits for Fixed Effects (`Effect3`, `Effect4`, `Effect5`).
//! *   [`effect_unbound`]: Traits for Parametric/Unbound Effects (`Effect3Unbound`, `Effect4Unbound`, `Effect5Unbound`).
//! *   [`monad_effect`]: Monadic operations for Fixed Effects.
//! *   [`monad_effect_unbound`]: Monadic operations for Parametric Effects (`pure`, `ibind`).

pub mod effect;
pub mod effect_log;
pub mod effect_unbound;
pub mod monad_effect;
pub mod monad_effect_unbound;
