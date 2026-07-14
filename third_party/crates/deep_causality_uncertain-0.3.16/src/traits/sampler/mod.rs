/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{ProbabilisticType, SampledValue, UncertainError, UncertainNodeContent};
use deep_causality_ast::ConstTree;

/// A trait for sampling strategies.
pub trait Sampler<T: ProbabilisticType> {
    /// Generates a single sample from the computation graph.
    fn sample(
        &self,
        root_node: &ConstTree<UncertainNodeContent>,
    ) -> Result<SampledValue, UncertainError>;
}
