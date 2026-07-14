/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Temporal, TimeKind, TimeScale};

impl Temporal<f64> for TimeKind {
    fn time_scale(&self) -> TimeScale {
        match self {
            TimeKind::Discrete(t) => t.time_scale(),
            TimeKind::Euclidean(t) => t.time_scale(),
            TimeKind::Entropic(t) => t.time_scale(),
            TimeKind::Lorentzian(t) => t.time_scale(),
            // TimeKind::Symbolic(t) => t.time_scale(),
        }
    }

    fn time_unit(&self) -> f64 {
        match self {
            TimeKind::Lorentzian(t) => t.time_unit(),
            TimeKind::Euclidean(t) => t.time_unit(),
            TimeKind::Discrete(t) => t.time_unit() as f64,
            TimeKind::Entropic(t) => t.time_unit() as f64,
            // TimeKind::Symbolic(t) => t.time_unit() as f64,
        }
    }
}
