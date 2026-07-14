/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Float;

/// Marker trait: Promises that a * (b + c)  == (a * b) + (a * c).
pub trait Distributive {}

impl<T> Distributive for T where T: Float {}

impl Distributive for i8 {}

impl Distributive for i16 {}

impl Distributive for i32 {}

impl Distributive for i64 {}

impl Distributive for i128 {}

impl Distributive for u8 {}

impl Distributive for u16 {}

impl Distributive for u32 {}

impl Distributive for u64 {}

impl Distributive for u128 {}

impl Distributive for isize {}

impl Distributive for usize {}
