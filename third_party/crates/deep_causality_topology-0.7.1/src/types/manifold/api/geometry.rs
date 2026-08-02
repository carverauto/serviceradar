/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Public geometry API for Manifold.

use crate::{Manifold, Simplex, SimplicialComplex, TopologyError};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField + FromPrimitive,
{
    /// Computes the squared volume of a k-simplex using Cayley-Menger determinant.
    ///
    /// # Returns
    /// * `Ok(C)` - The squared volume in **metric precision** `C` (the precision of
    ///   the underlying `ReggeGeometry<C>`). The manifold's data precision `D`
    ///   does not enter this computation; the volume is a metric quantity.
    /// * `Err(TopologyError)` - If metric is missing or edges not found.
    pub fn simplex_volume_squared(&self, simplex: &Simplex) -> Result<C, TopologyError> {
        self.simplex_volume_squared_impl(simplex)
    }
}
