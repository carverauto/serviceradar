/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{LorentzianSpacetime, SpaceTemporal};

impl SpaceTemporal<f64, f64> for LorentzianSpacetime {
    fn t(&self) -> &f64 {
        &self.t
    }
}
