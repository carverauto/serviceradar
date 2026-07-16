/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{EuclideanSpace, Identifiable};

impl Identifiable for EuclideanSpace {
    fn id(&self) -> u64 {
        self.id
    }
}
