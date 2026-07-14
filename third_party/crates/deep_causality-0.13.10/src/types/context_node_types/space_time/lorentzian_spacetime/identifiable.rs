/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Identifiable, LorentzianSpacetime};

impl Identifiable for LorentzianSpacetime {
    fn id(&self) -> u64 {
        self.id
    }
}
