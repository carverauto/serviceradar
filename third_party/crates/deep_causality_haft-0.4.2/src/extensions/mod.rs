/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Concrete HKT Witness Implementations (Extensions).
//!
//! This module provides the "Witness" types that bridge standard Rust library types to the
//! Higher-Kinded Type (HKT) traits defined in `core` and `algebra`.
//!
//! # How it Works
//!
//! Since Rust types like `Vec<T>` are not types themselves (they are type constructors), we cannot
//! implement `Functor` directly on `Vec`. Instead, we define a struct `VecWitness` that implements `HKT`.
//!
//! ```rust,ignore
//! struct VecWitness;
//! impl HKT for VecWitness {
//!     type Type<T> = Vec<T>;
//! }
//! impl Functor<VecWitness> for VecWitness { ... }
//! ```
//!
//! You then use `VecWitness::fmap(vec, func)` to perform operations.
//!
//! # Supported Types
//!
//! The following standard library types have HKT witnesses provided:
//!
//! ## Collections
//! *   [`VecWitness`](hkt_vec_ext::VecWitness): For `Vec<T>`.
//! *   [`VecDequeWitness`](func_fold_vec_deque_ext::VecDequeWitness): For `VecDeque<T>`.
//! *   [`LinkedListWitness`](hkt_linked_list_ext::LinkedListWitness): For `LinkedList<T>`.
//! *   [`HashMapWitness`](func_fold_hash_map_ext::HashMapWitness): For `HashMap<K, V>` (Functor maps over values).
//! *   [`BTreeMapWitness`](func_fold_b_tree_map_ext::BTreeMapWitness): For `BTreeMap<K, V>` (Functor maps over values).
//!
//! ## Control Flow & Wrappers
//! *   [`OptionWitness`](hkt_option_ext::OptionWitness): For `Option<T>`.
//! *   [`ResultWitness`](hkt_result_ext::ResultWitness): For `Result<T, E>` (Fixed Error).
//! *   [`ResultUnboundWitness`](hkt_result_ext::ResultUnboundWitness): For `Result<T, E>` (Unbound/Bifunctor).
//! *   [`BoxWitness`](hkt_box_ext::BoxWitness): For `Box<T>`.
//!
//! ## Tuples
//! *   [`Tuple2Witness`](hkt_tuple_ext::Tuple2Witness): For `(A, B)`.
//! *   [`Tuple3Witness`](hkt_tuple_ext::Tuple3Witness): For `(A, B, C)`.
#[cfg(feature = "alloc")]
pub mod func_fold_b_tree_map_ext;
#[cfg(feature = "std")]
pub mod func_fold_hash_map_ext;
#[cfg(feature = "alloc")]
pub mod func_fold_vec_deque_ext;
#[cfg(feature = "alloc")]
pub mod hkt_box_ext;
#[cfg(feature = "alloc")]
pub mod hkt_linked_list_ext;
pub mod hkt_option_ext;
pub mod hkt_result_ext;
pub mod hkt_tuple_ext;
#[cfg(feature = "alloc")]
pub mod hkt_vec_ext;
