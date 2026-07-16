/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![cfg_attr(not(feature = "std"), no_std)]
#[cfg(feature = "alloc")]
extern crate alloc;
extern crate core;

mod alias;
mod errors;
mod traits;
mod types;

// Re-export alias types
pub use crate::alias::*;

// Re-export error types
pub use crate::errors::causality_error::{CausalityError, CausalityErrorEnum};

// Re-export traits
pub use crate::traits::alternatable::Alternatable;
pub use crate::traits::alternatable_context::AlternatableContext;
pub use crate::traits::alternatable_state::AlternatableState;
pub use crate::traits::alternatable_value::AlternatableValue;
pub use crate::traits::causal_monad::CausalMonad;

// Re-export types
pub use crate::types::causal_arrow::{
    CausalArrow, CausalArrowBuilder, CausalFlowOut, CausalLift, KleisliCompose, causal_arrow,
};
pub use crate::types::causal_command::{CausalCommand, CausalCommandWitness};
pub use crate::types::causal_effect::CausalEffect;
pub use crate::types::causal_effect_propagation_process::CausalEffectPropagationProcess;
pub use crate::types::causal_effect_propagation_process::hkt::CausalEffectPropagationProcessWitness;
pub use crate::types::causal_flow::CausalFlow;
pub use crate::types::effect_log::log_effect::EffectLog;
// IO file actions (std-only): concrete `IoAction`s reading/writing files, fixing
// `Error = CausalityError`. The `IoAction` trait itself lives in `deep_causality_haft`.
#[cfg(feature = "std")]
pub use crate::types::io::{
    ReadCsv, ReadText, WriteCsv, WriteText, read_csv, read_text, write_csv, write_text,
};
pub use crate::types::propagating_effect::PropagatingEffect;
pub use crate::types::propagating_effect::hkt::PropagatingEffectWitness;
pub use crate::types::propagating_process::PropagatingProcess;
pub use crate::types::propagating_process::hkt::PropagatingProcessWitness;
pub use deep_causality_haft::Either;
