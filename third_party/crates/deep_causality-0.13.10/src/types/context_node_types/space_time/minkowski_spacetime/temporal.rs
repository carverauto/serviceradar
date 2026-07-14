/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{MinkowskiSpacetime, Temporal, TimeScale};

impl Temporal<f64> for MinkowskiSpacetime {
    fn time_scale(&self) -> TimeScale {
        self.time_scale
    }

    fn time_unit(&self) -> f64 {
        self.t
    }
}
