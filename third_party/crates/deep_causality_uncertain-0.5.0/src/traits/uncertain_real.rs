/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ProbabilisticType, UncertainNodeContent};

/// Node-construction boundary for the real-valued uncertain instantiations.
///
/// This lets `Uncertain::point` / `normal` / `uniform` be a **single generic** impl over
/// `T: UncertainReal` rather than one impl per concrete float. That matters for source
/// compatibility: with a single candidate impl, `Uncertain::normal(0.0, 1.0)` still infers
/// `f64` by the usual `{float}` literal fallback, so existing f64 call sites need no
/// annotation. Each concrete type maps itself to the matching closed-`SampledValue` node
/// variant (`DistributionF64` vs `DistributionF106`), which is the per-type detail.
pub trait UncertainReal: ProbabilisticType {
    /// Build the normal-distribution leaf node at this type's precision.
    fn normal_node(mean: Self, std_dev: Self) -> UncertainNodeContent;

    /// Build the uniform-distribution leaf node at this type's precision.
    fn uniform_node(low: Self, high: Self) -> UncertainNodeContent;
}
