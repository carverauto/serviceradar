/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod display;
mod getters;
mod identifiable;

use crate::ActionParameterValue;
use std::collections::HashMap;

/// Represents an action that the system intends to perform, submitted
/// for evaluation by the Effect Ethos.
///
/// It contains a unique identifier for the class of action, a descriptive name, and a map
/// of specific parameters for this instance of the action.
#[derive(Debug, Clone, PartialEq)]
pub struct ProposedAction {
    /// A unique identifier for this action instance.
    action_id: u64,
    /// A string description of the proposed action (e.g., "vehicle.drive").
    action_name: String,
    /// A map of specific parameters for this action instance.
    /// (e.g., {"speed": ActionParameterValue::Number(30.0)})
    parameters: HashMap<String, ActionParameterValue>,
}

impl ProposedAction {
    /// Creates a new `ProposedAction`.
    pub fn new(
        action_id: u64,
        action_name: String,
        parameters: HashMap<String, ActionParameterValue>,
    ) -> Self {
        Self {
            action_id,
            action_name,
            parameters,
        }
    }
}
