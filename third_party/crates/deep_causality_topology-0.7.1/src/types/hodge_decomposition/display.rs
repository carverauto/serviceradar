/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::fmt;

use crate::types::hodge_decomposition::HodgeDecomposition;
use deep_causality_algebra::RealField;

impl<R: RealField> fmt::Display for HodgeDecomposition<R> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "HodgeDecomposition(grade={}, exact_len={}, co_exact_len={}, harmonic_len={})",
            self.grade(),
            self.exact().as_slice().len(),
            self.co_exact().as_slice().len(),
            self.harmonic().as_slice().len(),
        )
    }
}
