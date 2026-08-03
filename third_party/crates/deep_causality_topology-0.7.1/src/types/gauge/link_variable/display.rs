/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GaugeGroup, LinkVariable};

impl<G: GaugeGroup, M: std::fmt::Debug + Clone, R> std::fmt::Display for LinkVariable<G, M, R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "LinkVariable<{}>(N={}, data={:?})",
            G::name(),
            G::matrix_dim(),
            self.data.as_slice()
        )
    }
}
