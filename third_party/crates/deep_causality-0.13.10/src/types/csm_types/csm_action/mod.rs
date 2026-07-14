/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::ActionError;

mod display;
mod fire;
mod getter;

/// A `CausalAction` represents an executable action that can be triggered in response to causal conditions.
///
/// In a causal state machine (CSM), actions are paired with causal states. When a causal state's
/// conditions are met (evaluated to true), the associated action is fired.
///
/// # Purpose
/// `CausalAction` encapsulates a function that performs a specific task, such as:
/// - Triggering alerts or alarms
/// - Logging events
/// - Sending notifications
/// - Executing control operations
///
/// # Usage
/// `CausalAction` is typically used in conjunction with `CausalState` in a state-action pair
/// within a causal state machine (CSM). The CSM evaluates states and, when conditions are met,
/// fires the associated actions.
///
/// # Example
/// ```
/// use deep_causality::{ActionError, CausalAction};
///
/// fn get_alert_action() -> CausalAction {
///     let func = || {
///         println!("Alert triggered!");
///         Ok(())
///     };
///     let descr = "Action that triggers an alert";
///     let version = 1;
///
///     CausalAction::new(func, descr, version)
/// }
/// ```
#[derive(Clone, Debug)]
pub struct CausalAction {
    // The function to execute when the action is fired.
    // This function should return `Ok(())` on success or an `ActionError` on failure.
    action: fn() -> Result<(), ActionError>,
    // A description of what the action does.
    description: &'static str,
    // The version number of the action, useful for tracking changes or updates.
    version: usize,
}

impl CausalAction {
    pub fn new(
        action: fn() -> Result<(), ActionError>,
        description: &'static str,
        version: usize,
    ) -> Self {
        Self {
            action,
            description,
            version,
        }
    }
}
