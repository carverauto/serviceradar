/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GaugeField, GaugeGroup};
use std::fmt::{Debug, Display};

impl<G: GaugeGroup, M: Debug, R: deep_causality_algebra::RealField> Display
    for GaugeField<G, M, R>
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "GaugeField<{}>(metric={:?}, conn={:?}, field_strength={:?})",
            G::name(),
            self.metric,
            self.connection.shape(),
            self.field_strength.shape()
        )
    }
}
