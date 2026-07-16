/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Identifiable, IdentificationValue, Observation};

impl Identifiable for Observation {
    fn id(&self) -> IdentificationValue {
        self.id
    }
}
