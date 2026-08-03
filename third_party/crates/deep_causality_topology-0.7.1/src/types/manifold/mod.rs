/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Manifold type for smooth geometric structures.
//!
//! `Manifold<K, F>` wraps any `ChainComplex` (simplicial, cubical, or user-defined) and
//! carries an associated field tensor + an optional metric. The metric type is
//! determined by the complex via the plain associated type `K::Metric` — its precision
//! flows from the complex's own type parameters (e.g. `SimplicialComplex<R>` →
//! `ReggeGeometry<R>`, `LatticeComplex<D, R>` → `CubicalReggeGeometry<D, R>`).
//!
//! **The data precision `F` is decoupled from the metric precision.** `F` carries no
//! struct-level trait bound; it may be `RealField` for scalar field data, a multivector
//! from `deep_causality_multivector`, a tensor from `deep_causality_tensor`, a dual
//! number for automatic differentiation, or any other algebraic type that flows through
//! `CausalTensor<F>`. Per-impl-block `F: RealField` bounds are added where numerical
//! operations against `F` actually require them (covariance, simplex volume, curvature
//! contractions, Cayley-Menger, Laplacian, codifferential). This decoupling is the
//! precondition for restoring the full HKT trait surface (`Functor`, `Monad`, `CoMonad`,
//! `Applicative`) on stable Rust — see `design.md` Decision 1 of
//! `generalize-topology-over-realfield` for the rationale.

use crate::SimplicialComplex;
use crate::traits::chain_complex::ChainComplex;
use deep_causality_tensor::CausalTensor;

mod api;
mod constructors;
mod covariance;
mod display;
mod geometry;
mod getters;
mod utils;

mod differential;
mod topology;

pub use differential::DecStencilTables;
pub use differential::HodgeDecomposeOptions;

/// A newtype wrapper around any `ChainComplex` that represents a Manifold.
///
/// `K` is the underlying chain complex; `F` is the field-data type on cells. `F` is
/// **unconstrained at the struct level** — see the module-level doc for the rationale.
#[derive(Debug, Clone, PartialEq)]
pub struct Manifold<K: ChainComplex, F> {
    /// The underlying chain complex, guaranteed to satisfy manifold properties when set.
    pub(crate) complex: K,
    /// The data associated with the manifold (e.g. scalar field values, multivectors,
    /// or tensors living on cells).
    pub(crate) data: CausalTensor<F>,
    /// The metric, typed by the complex via the plain associated type `K::Metric`.
    pub(crate) metric: Option<K::Metric>,
    /// The Focus (Cursor) for Comonadic extraction.
    pub(crate) cursor: usize,
}

/// Textbook alias for the simplicial case: `Manifold<SimplicialComplex<R>, F>`.
///
/// `R` is the precision of the simplicial complex (and its `ReggeGeometry<R>` metric);
/// `F` is the field-data type on simplices and may differ from `R`.
pub type SimplicialManifold<R, F> = Manifold<SimplicialComplex<R>, F>;
