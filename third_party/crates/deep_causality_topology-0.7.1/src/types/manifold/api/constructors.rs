/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Constructors for Manifold type.

use crate::{ReggeGeometry, SimplicialComplex, TopologyError};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use super::super::Manifold;

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField + FromPrimitive,
{
    /// Attempts to create a new `Manifold` from a `SimplicialComplex` and data.
    ///
    /// This constructor performs rigorous checks to ensure the complex satisfies
    /// manifold criteria including orientation and link conditions.
    ///
    /// # Arguments
    /// * `complex` - The underlying simplicial complex
    /// * `data` - Tensor data associated with simplices
    /// * `cursor` - Initial cursor position for comonadic operations
    ///
    /// # Returns
    /// * `Ok(Manifold)` - A valid manifold
    /// * `Err(TopologyError)` - If validation fails
    ///
    /// # Example
    /// ```rust,ignore
    /// let manifold = Manifold::new(complex, data, 0)?;
    /// ```
    pub fn new(
        complex: SimplicialComplex<C>,
        data: CausalTensor<D>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        Self::new_impl(complex, data, cursor)
    }

    /// Creates a Manifold with an associated Regge geometry metric.
    ///
    /// # Arguments
    /// * `complex` - The underlying simplicial complex
    /// * `data` - Tensor data associated with simplices
    /// * `metric` - Optional Regge geometry containing edge lengths
    /// * `cursor` - Initial cursor position
    ///
    /// # Returns
    /// * `Ok(Manifold)` - A valid manifold with metric
    /// * `Err(TopologyError)` - If validation fails
    pub fn with_metric(
        complex: SimplicialComplex<C>,
        data: CausalTensor<D>,
        metric: Option<ReggeGeometry<C>>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        Self::with_metric_impl(complex, data, metric, cursor)
    }
}

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField + FromPrimitive,
    D: Clone,
{
    /// Creates a shallow clone of the Manifold with cursor reset to 0.
    ///
    /// `D` carries no `RealField` bound here — only `Clone`. This method is purely
    /// structural (cloning complex, data tensor, metric, and cursor), so cross-algebra
    /// cell data (multivectors, tensors, dual numbers) flows through unchanged. `C`
    /// must be `RealField` because that is what the underlying `SimplicialComplex<C>`
    /// requires to exist as a `ChainComplex`.
    pub fn clone_shallow(&self) -> Self {
        Self::clone_shallow_impl(self)
    }
}

// -- Cubical constructors (Stage C) ----------------------------------------

use crate::types::lattice_complex::LatticeComplex;

impl<const D: usize, R: RealField, F> Manifold<LatticeComplex<D, R>, F> {
    /// Construct a manifold over a cubical complex without a metric (raw assembly).
    ///
    /// `R` is the lattice (metric) precision; `F` is the data type carried in cells.
    /// The two are independent per the Option 2C design: `F` may be a scalar (`f32`,
    /// `f64`, `Float106`), a multivector from `deep_causality_multivector`, a tensor
    /// from `deep_causality_tensor`, a dual number, etc. The cubical lattice's
    /// precision does not constrain what flavor of value sits on its cells.
    ///
    /// Validation is minimal here; richer cell-count validation belongs in a follow-up
    /// that lifts the simplicial `new`/`with_metric` validation logic to a
    /// complex-agnostic trait method.
    pub fn from_cubical(
        complex: LatticeComplex<D, R>,
        data: CausalTensor<F>,
        cursor: usize,
    ) -> Self {
        Self {
            complex,
            data,
            metric: None,
            cursor,
        }
    }

    /// Construct a manifold over a cubical complex with a `CubicalReggeGeometry<D, R>`.
    ///
    /// Metric precision `R` is independent of cell-data type `F` (see `from_cubical`).
    pub fn from_cubical_with_metric(
        complex: LatticeComplex<D, R>,
        data: CausalTensor<F>,
        metric: crate::CubicalReggeGeometry<D, R>,
        cursor: usize,
    ) -> Self {
        Self {
            complex,
            data,
            metric: Some(metric),
            cursor,
        }
    }
}
