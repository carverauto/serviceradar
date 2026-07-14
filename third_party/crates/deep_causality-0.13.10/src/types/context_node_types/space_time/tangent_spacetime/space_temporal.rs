/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{SpaceTemporal, TangentSpacetime};

impl SpaceTemporal<f64, f64> for TangentSpacetime {
    fn t(&self) -> &f64 {
        &self.t
    }
}
