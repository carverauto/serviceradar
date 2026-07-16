/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{EntropicTime, ScalarProjector, Temporal};

impl ScalarProjector for EntropicTime {
    type Scalar = u64;

    fn project(&self) -> Self::Scalar {
        self.time_unit()
    }
}
