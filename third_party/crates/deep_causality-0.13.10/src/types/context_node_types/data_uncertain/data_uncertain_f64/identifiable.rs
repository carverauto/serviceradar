/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Identifiable, UncertainFloat64Data};

impl Identifiable for UncertainFloat64Data {
    fn id(&self) -> u64 {
        self.id
    }
}
