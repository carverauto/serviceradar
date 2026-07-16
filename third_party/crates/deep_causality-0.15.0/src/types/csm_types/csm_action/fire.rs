/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ActionError, CausalAction};

impl CausalAction {
    /// Executes the action function encapsulated by this `CausalAction`.
    ///
    /// This method is typically called by a causal state machine (CSM) when
    /// the associated causal state's conditions are met.
    ///
    /// # Returns
    /// - `Ok(())` if the action executes successfully
    /// - `Err(ActionError)` if the action fails
    ///
    /// # Example
    /// ```
    /// use deep_causality::{ActionError, CausalAction};
    ///
    /// // Create a CausalAction
    /// let action = CausalAction::new(
    ///     || { println!("Action executed!"); Ok(()) },
    ///     "Example action",
    ///     1
    /// );
    ///
    /// // Fire the action
    /// match action.fire() {
    ///     Ok(()) => println!("Action completed successfully"),
    ///     Err(e) => println!("Action failed: {}", e),
    /// }
    /// ```
    pub fn fire(&self) -> Result<(), ActionError> {
        (self.action)()
    }
}
