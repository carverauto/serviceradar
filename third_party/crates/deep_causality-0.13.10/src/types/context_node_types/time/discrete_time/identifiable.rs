/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{DiscreteTime, Identifiable};

impl Identifiable for DiscreteTime {
    fn id(&self) -> u64 {
        self.id
    }
}
