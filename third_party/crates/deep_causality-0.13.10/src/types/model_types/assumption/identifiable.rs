/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::model_types::assumption::Assumption;
use crate::{Identifiable, IdentificationValue};

impl Identifiable for Assumption {
    fn id(&self) -> IdentificationValue {
        self.id
    }
}
