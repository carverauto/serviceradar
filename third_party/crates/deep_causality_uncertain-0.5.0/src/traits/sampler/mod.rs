/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{ProbabilisticType, SampledValue, UncertainError, UncertainNodeContent};
use deep_causality_ast::ConstTree;

/// A trait for sampling strategies.
pub trait Sampler<T: ProbabilisticType> {
    /// Generates a single sample from the computation graph at the given sample index.
    ///
    /// `sample_index` selects the draw: the `SequentialSampler` ignores it (it draws from a
    /// stateful RNG and the index only tags the cache entry), whereas the `QmcSampler` uses it
    /// as the index of the low-discrepancy point.
    fn sample(
        &self,
        root_node: &ConstTree<UncertainNodeContent>,
        sample_index: u64,
    ) -> Result<SampledValue, UncertainError>;
}
