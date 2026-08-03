/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::fmt;

use crate::types::topological_invariants::TopologicalInvariants;
use deep_causality_algebra::RealField;

impl<R: RealField + fmt::Display> fmt::Display for TopologicalInvariants<R> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let b = self.betti_numbers();
        write!(
            f,
            "TopologicalInvariants(betti=[{},{},{},{}], exact_l2={}, co_exact_l2={}, harmonic_l2={})",
            b[0],
            b[1],
            b[2],
            b[3],
            self.exact_l2_norm(),
            self.co_exact_l2_norm(),
            self.harmonic_l2_norm(),
        )
    }
}
