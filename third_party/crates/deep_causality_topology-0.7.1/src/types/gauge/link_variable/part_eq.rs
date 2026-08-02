/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GaugeGroup, LinkVariable};

impl<G: GaugeGroup, R: PartialEq, T: PartialEq> PartialEq for LinkVariable<G, R, T> {
    fn eq(&self, other: &Self) -> bool {
        self.data.as_slice() == other.data.as_slice()
    }
}
