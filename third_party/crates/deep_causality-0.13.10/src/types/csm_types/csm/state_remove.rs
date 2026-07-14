/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CSM, CsmEvaluable, UpdateError};
use std::fmt::Debug;

impl<I, O, C> CSM<I, O, C>
where
    I: Default + Clone,
    O: CsmEvaluable + Default + Debug + Clone,
    C: Clone,
{
    /// Removes a state action at the index position id.
    /// Returns UpdateError if the index does not exist.
    pub fn remove_single_state(&self, id: usize) -> Result<(), UpdateError> {
        let mut binding = self.state_actions.write().unwrap();

        if binding.remove(&id).is_none() {
            return Err(UpdateError(format!(
                "State {id} does not exist and cannot be removed"
            )));
        }

        Ok(())
    }
}
