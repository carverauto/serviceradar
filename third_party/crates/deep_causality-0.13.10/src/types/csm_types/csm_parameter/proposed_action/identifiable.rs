/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Identifiable;
use crate::ProposedAction;

impl Identifiable for ProposedAction {
    fn id(&self) -> u64 {
        self.action_id
    }
}
