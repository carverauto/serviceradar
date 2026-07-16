/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Trait for types that have a unique identifier.
///
/// Provides:
/// - id(): Get the unique ID for this item
///
pub trait Identifiable {
    fn id(&self) -> u64;
}
