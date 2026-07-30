/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Metric;
use std::hash::{Hash, Hasher};

impl Hash for Metric {
    fn hash<H: Hasher>(&self, state: &mut H) {
        core::mem::discriminant(self).hash(state);
        match self {
            Metric::Euclidean(d)
            | Metric::NonEuclidean(d)
            | Metric::Minkowski(d)
            | Metric::Lorentzian(d)
            | Metric::PGA(d) => d.hash(state),
            Metric::Generic { p, q, r } => {
                p.hash(state);
                q.hash(state);
                r.hash(state);
            }
            Metric::Custom {
                dim,
                neg_mask,
                zero_mask,
            } => {
                dim.hash(state);
                neg_mask.hash(state);
                zero_mask.hash(state);
            }
        }
    }
}
