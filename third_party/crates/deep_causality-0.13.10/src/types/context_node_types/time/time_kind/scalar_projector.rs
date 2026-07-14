/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ScalarProjector, TimeKind};

impl ScalarProjector for TimeKind {
    type Scalar = f64;

    fn project(&self) -> Self::Scalar {
        match self {
            TimeKind::Discrete(t) => t.project() as f64,
            TimeKind::Euclidean(t) => t.project(),
            TimeKind::Entropic(t) => t.project() as f64,
            TimeKind::Lorentzian(t) => t.project(),
            // TimeKind::Symbolic(t) => t.project(),
        }
    }
}
