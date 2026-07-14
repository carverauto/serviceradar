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
