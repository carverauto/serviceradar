/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! A persistent, immutable tree data structure.
//!
//! This crate provides `ConstTree<T>`, a thread-safe, reference-counted,
//! persistent (copy-on-write) tree structure.
//!
//! ## Features
//!
//! - **Persistent**: Modifying a tree creates a new version without altering the original.
//!   Unchanged parts of the tree are shared, making modifications cheap.
//! - **Thread-Safe**: `ConstTree<T>` is `Send` and `Sync` if `T` is, allowing it to be
//!   safely shared across threads.
//! - **Rich API**: Includes constructors, accessors, search methods, iterators,
//!   and functional transformation methods.
//!   - Multiple iteration strategies (pre-order, post-order, level-order, consuming).
//!   - Consuming (`into_map`) and non-consuming (`map`) mapping methods.
//!   - Monadic `join` method to flatten a `ConstTree<ConstTree<T>>`.
//! - **Ergonomic**: Implements standard traits like `Debug`, `Display`, `Clone`, `PartialEq`,
//!   `Default`, and `From<T>`.
//!
//! This crate serves as a foundational building block for implementing Higher-Kinded Type
//! traits (like `Functor`, `Monad`, etc.) on other data structures, such as `Uncertain<T>`,
//! by providing the necessary tree manipulation primitives.
mod const_tree;

pub use crate::const_tree::ConstTree;
