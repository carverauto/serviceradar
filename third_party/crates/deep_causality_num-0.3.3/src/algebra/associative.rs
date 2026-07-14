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

/// Marker trait: Promises that (a * b) * c == a * (b * c).
/// IMPLEMENT THIS for f64, f32, Float, Complex, Quaternion.
/// DO NOT IMPLEMENT for Octonion.
pub trait Associative {}

impl<T> Associative for T where T: Float {}

impl Associative for i8 {}

impl Associative for i16 {}

impl Associative for i32 {}

impl Associative for i64 {}

impl Associative for i128 {}

impl Associative for u8 {}

impl Associative for u16 {}

impl Associative for u32 {}

impl Associative for u64 {}

impl Associative for u128 {}

impl Associative for isize {}

impl Associative for usize {}
