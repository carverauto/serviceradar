/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Core components for the `deep_causality_uncertain` crate.

mod algos;
mod alias;
mod errors;
mod extensions;
mod traits;
mod types;

// Algos
pub use crate::algos::hypothesis::sprt_eval;
// Alias
pub use crate::alias::{
    MaybeUncertainBool, MaybeUncertainF64, MaybeUncertainF106, UncertainBool, UncertainF64,
    UncertainF106,
};
// Errors
pub use crate::errors::UncertainError;
// Traits
pub use crate::traits::probabilistic::{FromSampledValue, IntoSampledValue, ProbabilisticType};
pub use crate::traits::sampler::Sampler;
pub use crate::traits::uncertain_real::UncertainReal;
// Types
pub use crate::types::cache::{GlobalSampleCache, SampledValue, SamplerKind, with_global_cache};
pub use crate::types::computation::operator::arithmetic_operator::ArithmeticOperator;
pub use crate::types::computation::operator::comparison_operator::ComparisonOperator;
pub use crate::types::computation::operator::logical_operator::LogicalOperator;
pub use crate::types::computation::uncertain_node_content::{
    SampledBindFn, SampledFmapFn, UncertainNodeContent,
};
pub use crate::types::distribution::DistributionEnum;
pub use crate::types::distribution_parameters::BernoulliParams;
pub use crate::types::distribution_parameters::NormalDistributionParams;
pub use crate::types::distribution_parameters::UniformDistributionParams;
pub use crate::types::sampler::qmc_sampler::QmcSampler;
pub use crate::types::sampler::sampler_seed::{clear_sampler_seed, seed_sampler};
pub use crate::types::sampler::sequential_sampler::SequentialSampler;
pub use crate::types::uncertain::Uncertain;
pub use crate::types::uncertain_maybe::MaybeUncertain;
