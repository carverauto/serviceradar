/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Float;

/// Marker trait: Promises that a * (b + c)  == (a * b) + (a * c).
pub trait Distributive {}

impl<T> Distributive for T where T: Float {}
