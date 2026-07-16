/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{EuclideanTime, Identifiable};

impl Identifiable for EuclideanTime {
    fn id(&self) -> u64 {
        self.id
    }
}
