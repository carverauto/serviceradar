/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{EntropicTime, Temporal, TimeScale};

impl Temporal<u64> for EntropicTime {
    fn time_scale(&self) -> TimeScale {
        TimeScale::NoScale
    }

    fn time_unit(&self) -> u64 {
        self.entropy_tick
    }
}
