/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Identifiable;
use deep_causality_uncertain::{ProbabilisticType, Uncertain};

/// Represents uncertain data entities in a context graph.
///
/// This trait marks nodes that carry domain-specific data
/// relevant to inference, observation, or explanation. It extends
/// [`Identifiable`] to ensure that each instance has a unique identity.
///
/// This trait is intentionally left minimal to allow full flexibility
/// in how data is modeled. You may wrap sensor input, encoded strings,
/// discrete values, or even external references.
///
pub trait UncertainDatable<T>: Identifiable
where
    T: ProbabilisticType,
{
    /// Returns the contained data.
    ///
    /// If `Self::Data` is `Copy`, this will typically return a copy. Otherwise, it may
    /// return a clone or a new instance depending on the implementation.
    fn get_data(&self) -> Uncertain<T>;

    /// Sets or updates the contained data with a new value.
    fn set_data(&mut self, value: Uncertain<T>);
}
