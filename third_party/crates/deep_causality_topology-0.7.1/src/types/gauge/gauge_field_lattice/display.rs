/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GaugeGroup, LatticeGaugeField};
use std::fmt::{Debug, Display};

impl<
    G: GaugeGroup,
    const D: usize,
    M: Debug,
    R: deep_causality_algebra::RealField + Debug,
    S: Debug,
> Display for LatticeGaugeField<G, D, M, R, S>
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "LatticeGaugeField<{}, {}D, {}>(links={}, β={:?})",
            G::name(),
            D,
            std::any::type_name::<M>().split("::").last().unwrap_or("?"),
            self.num_links(),
            self.beta
        )
    }
}
