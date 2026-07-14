/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::MulGroup;

/// A marker trait for a **Division Group**.
///
/// This trait is an alias for `MulGroup` and is used to semantically represent
/// the group of non-zero elements of a `Field` or `DivisionRing` under the
/// operation of multiplication.
///
/// In such a structure, division `a / b` is equivalent to multiplication by an
/// inverse, `a * b⁻¹`. Therefore, a group that supports division is inherently
/// a multiplicative group.
pub trait DivGroup: MulGroup {}

// Blanket Implementation
impl<T: MulGroup> DivGroup for T {}
