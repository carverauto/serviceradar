/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Metric;
use core::fmt;

impl fmt::Display for Metric {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Metric::Euclidean(d) => write!(f, "Euclidean({})", d),
            Metric::NonEuclidean(d) => write!(f, "NonEuclidean({})", d),
            Metric::Minkowski(d) => write!(f, "Minkowski({})", d),
            Metric::Lorentzian(d) => write!(f, "Lorentzian({})", d),
            Metric::PGA(d) => write!(f, "PGA({})", d),
            Metric::Generic { p, q, r } => write!(f, "Cl({}, {}, {})", p, q, r),
            Metric::Custom { dim, .. } => write!(f, "Custom({})", dim),
        }
    }
}
