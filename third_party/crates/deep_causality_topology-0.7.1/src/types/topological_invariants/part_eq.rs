/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::topological_invariants::TopologicalInvariants;
use deep_causality_algebra::RealField;

impl<R: RealField> PartialEq for TopologicalInvariants<R> {
    fn eq(&self, other: &Self) -> bool {
        self.betti_numbers() == other.betti_numbers()
            && self.exact_l2_norm() == other.exact_l2_norm()
            && self.co_exact_l2_norm() == other.co_exact_l2_norm()
            && self.harmonic_l2_norm() == other.harmonic_l2_norm()
    }
}
