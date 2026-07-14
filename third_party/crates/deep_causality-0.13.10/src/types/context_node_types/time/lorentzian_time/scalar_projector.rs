/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{LorentzianTime, ScalarProjector, Temporal};

impl ScalarProjector for LorentzianTime {
    type Scalar = f64;

    fn project(&self) -> Self::Scalar {
        self.time_unit()
    }
}
