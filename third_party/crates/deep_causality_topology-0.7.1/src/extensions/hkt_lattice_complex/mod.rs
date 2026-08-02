/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::LatticeComplex;
use deep_causality_algebra::RealField;
use deep_causality_haft::{HKT, NoConstraint, Satisfies};
use std::sync::Arc;

/// HKT witness for `LatticeComplex<D, R>` as a functor over field values.
pub struct LatticeComplexWitness<const D: usize, R: RealField>(std::marker::PhantomData<R>);

impl<const D: usize, R: RealField> HKT for LatticeComplexWitness<D, R> {
    type Constraint = NoConstraint;
    type Type<T>
        = LatticeField<D, R, T>
    where
        T: Satisfies<NoConstraint>;
}

/// A field assignment over lattice cells.
/// Simplified implementation: map from cell indices (or linearized index) to value.
pub struct LatticeField<const D: usize, R: RealField, T> {
    pub lattice: Arc<LatticeComplex<D, R>>,
    pub values: Vec<T>, // Linearized values
}
