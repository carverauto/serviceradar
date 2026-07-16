/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
#[cfg(feature = "alloc")]
use alloc::format;
#[cfg(feature = "alloc")]
use alloc::string::String;

use crate::CausalEffectPropagationProcess;
use core::fmt::{Debug, Display};
use deep_causality_haft::LogSize;

impl<Value: Debug, Error: Debug, Log: Debug + Display + LogSize>
    CausalEffectPropagationProcess<Value, (), (), Error, Log>
{
    /// Generates a human-readable explanation of the causal computation's history.
    ///
    /// This method iterates over the accumulated logs, providing a comprehensive
    /// history of the computation, including the final value and any errors.
    ///
    /// # Returns
    ///
    /// A `String` containing the formatted explanation.
    pub fn explain(&self) -> String {
        let mut explanation = String::new();

        match &self.outcome {
            Ok(value) => explanation.push_str(&format!("Final Value: {:?}\n", value)),
            Err(error) => explanation.push_str(&format!("Error: {:?}\n", error)),
        }

        if !self.logs.is_empty() {
            explanation.push_str("--- Logs ---\n");
            explanation.push_str(&format!("{}", self.logs));
        }

        explanation
    }
}
