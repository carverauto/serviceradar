/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::AddGroup;

/// A marker trait for an **Abelian Group** (also known as a Commutative Group).
///
/// An Abelian group is a `Group` where the binary operation is commutative.
/// This means that the order of the operands does not affect the result.
///
/// # Mathematical Definition
///
/// A group `(G, *)` is Abelian if it satisfies the following additional law:
///
/// 1.  **Commutativity:** `a * b = b * a` for all `a, b` in `G`.
///
/// Since this trait builds on `AddGroup`, the operation is `+`, and the law is
/// `a + b = b + a`.
///
/// # Note on Implementation
///
/// This is a **marker trait**. It has no methods and provides no new functionality.
/// Its purpose is to signal at the type level that the commutativity law holds.
/// The compiler cannot verify this law, so implementing this trait is a promise
/// by the developer that the underlying type's addition operation is commutative.
pub trait AbelianGroup: AddGroup {}

// Automatic impls for standard types we know are Abelian.
// The default impl for f32 and f64 is in the field_real file for coherence with the complex field trait hierarchy.
impl AbelianGroup for i8 {}
impl AbelianGroup for i16 {}
impl AbelianGroup for i32 {}
impl AbelianGroup for i64 {}
impl AbelianGroup for i128 {}
impl AbelianGroup for u8 {}
impl AbelianGroup for u16 {}
impl AbelianGroup for u32 {}
impl AbelianGroup for u64 {}
impl AbelianGroup for u128 {}
impl AbelianGroup for isize {}
impl AbelianGroup for usize {}

// Note: Complex, Dual, and MultiVector (Vector addition) are also Abelian.
// Impl this trait for them in their respective crates.
