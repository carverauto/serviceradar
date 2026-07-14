/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Float;

// ## Summary of the "Three Markers"
//
// | Type | `Distributive` | `Associative` | `Commutative` | Trait |
// | :--- | :---: | :---: | :---: | :--- |
// | **Real (`f64`)** | ✅ | ✅ | ✅ | `Field` |
// | **Complex** | ✅ | ✅ | ✅ | `Field` |
// | **Quaternion** | ✅ | ✅ | ❌ | `AssociativeRing` |
// | **Octonion** | ✅ | ❌ | ❌ | `DivisionAlgebra` |
// | **Matrix** | ✅ | ✅ | ❌ | `AssociativeRing` |

/// Marker trait: Promises that a * b == b * a.
/// IMPLEMENT THIS for f64, f32, Float, Complex.
/// DO NOT IMPLEMENT for Quaternion, Octonion.
pub trait Commutative {}

impl<T> Commutative for T where T: Float {}

impl Commutative for i8 {}

impl Commutative for i16 {}

impl Commutative for i32 {}

impl Commutative for i64 {}

impl Commutative for i128 {}

impl Commutative for u8 {}

impl Commutative for u16 {}

impl Commutative for u32 {}

impl Commutative for u64 {}

impl Commutative for u128 {}

impl Commutative for isize {}

impl Commutative for usize {}
