/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ProposedAction;

impl std::fmt::Display for ProposedAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "ProposedAction {{ action_id: {}, action_name: {}, parameters: {:?} }}",
            self.action_id, self.action_name, self.parameters
        )
    }
}
