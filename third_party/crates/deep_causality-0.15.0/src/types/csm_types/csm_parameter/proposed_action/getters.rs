/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ActionParameterValue, ProposedAction};
use std::collections::HashMap;

impl ProposedAction {
    /// Returns the unique identifier of the proposed action.
    ///
    /// # Returns
    ///
    /// A `u64` representing the action's ID.
    pub fn action_id(&self) -> u64 {
        self.action_id
    }

    /// Returns the name of the proposed action.
    ///
    /// # Returns
    ///
    /// A string slice (`&str`) representing the action's name.
    pub fn action_name(&self) -> &str {
        &self.action_name
    }

    /// Returns a reference to the parameters associated with the proposed action.
    ///
    /// # Returns
    ///
    /// A reference to a `HashMap` where keys are `String` (parameter names) and values are `ActionParameterValue`.
    pub fn parameters(&self) -> &HashMap<String, ActionParameterValue> {
        &self.parameters
    }
}
