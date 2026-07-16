/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ActionError, CausalAction};

impl CausalAction {
    pub fn action(&self) -> fn() -> Result<(), ActionError> {
        self.action
    }

    pub fn description(&self) -> &'static str {
        self.description
    }

    pub fn version(&self) -> usize {
        self.version
    }
}
