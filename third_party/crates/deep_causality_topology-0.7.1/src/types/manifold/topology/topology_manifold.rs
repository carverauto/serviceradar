/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::manifold::utils;
use crate::{Manifold, ManifoldTopology, SimplicialComplex};

impl<C: deep_causality_algebra::RealField, D> ManifoldTopology
    for Manifold<SimplicialComplex<C>, D>
{
    fn is_oriented(&self) -> bool {
        utils::is_oriented(&self.complex)
    }

    fn satisfies_link_condition(&self) -> bool {
        utils::satisfies_link_condition(&self.complex)
    }

    fn euler_characteristic(&self) -> isize {
        utils::euler_characteristic(&self.complex)
    }

    fn has_boundary(&self) -> bool {
        utils::has_boundary(&self.complex)
    }
}
