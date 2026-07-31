/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// Super trait for full Log implementation.
pub trait LogEffect: LogAddEntry + LogAppend + LogSize {}

pub trait LogAddEntry {
    fn add_entry(&mut self, message: &str);
}

/// Trait for types that can append log entries from another instance of themselves.
pub trait LogAppend {
    /// Appends the log entries from `other` into `self`.
    fn append(&mut self, other: &mut Self);
}

pub trait LogSize {
    fn is_empty(&self) -> bool;
    fn len(&self) -> usize;
}
