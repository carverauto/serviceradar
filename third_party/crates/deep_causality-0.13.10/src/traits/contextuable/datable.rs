/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Identifiable;

/// Represents data-bearing entities in a context graph.
///
/// This trait marks nodes that carry domain-specific data
/// relevant to inference, observation, or explanation. It extends
/// [`Identifiable`] to ensure that each instance has a unique identity.
///
/// This trait is intentionally left minimal to allow full flexibility
/// in how data is modeled. You may wrap sensor input, encoded strings,
/// discrete values, or even external references.
///
pub trait Datable: Identifiable {
    type Data;

    /// Returns the contained data.
    ///
    /// If `Self::Data` is `Copy`, this will typically return a copy. Otherwise, it may
    /// return a clone or a new instance depending on the implementation.
    fn get_data(&self) -> Self::Data;

    /// Sets or updates the contained data with a new value.
    fn set_data(&mut self, value: Self::Data);
}
