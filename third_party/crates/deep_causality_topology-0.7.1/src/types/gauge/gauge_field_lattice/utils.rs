/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GaugeGroup, LatticeCell, LatticeGaugeField, LinkVariable};
use deep_causality_algebra::Field;
use deep_causality_algebra::{ComplexField, DivisionAlgebra, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
use std::fmt::Debug;

impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Get a link, returning identity if not found.
    pub(crate) fn get_link_or_identity(&self, edge: &LatticeCell<D>) -> LinkVariable<G, M, R> {
        self.links
            .get(edge)
            .cloned()
            .unwrap_or_else(LinkVariable::identity)
    }
}
