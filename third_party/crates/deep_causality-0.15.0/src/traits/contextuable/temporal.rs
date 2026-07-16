/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Identifiable, TimeScale};

/// Represents entities that have intrinsic temporal properties.
///
/// This trait provides access to both the **scale** (e.g. seconds, minutes)
/// and **unit value** (e.g. timestamp, frame number) associated with a temporal point.
///
/// Use this for any node, edge, or context that evolves over time or contributes
/// to time-dependent reasoning.
///
/// # Notes
/// The numeric type `V` must support ordering and arithmetic if used for inference.
pub trait Temporal<VT>: Identifiable {
    /// Returns the unit scale of time (e.g. `TimeScale::Milliseconds`).
    fn time_scale(&self) -> TimeScale;

    /// Returns a reference to the numeric time unit (e.g. 0, 100, 32768).
    fn time_unit(&self) -> VT;
}
