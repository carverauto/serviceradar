/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Hodge–Helmholtz decomposition carrier type.
//!
//! `HodgeDecomposition<R>` holds the three pairwise-orthogonal components produced
//! by the discrete Hodge–Helmholtz decomposition of a k-form ω on a `Manifold<K, R>`:
//!
//! ```text
//! ω = d α  +  δ β  +  h
//!     └─┬┘    └┬┘    └┬┘
//!    exact  co-exact harmonic
//! ```
//!
//! where `d` is the exterior derivative, `δ` is the codifferential, and `h` lies in
//! the kernel of the Hodge–Laplacian `Δ_k = δd + dδ`. On a finite simplicial or
//! cubical complex, the three components are uniquely determined by ω up to numerical
//! tolerance.
//!
//! The decomposition itself is produced by `Manifold::hodge_decompose` (landed in H2);
//! this module ships only the carrier type and its access surface (constructor,
//! getters, `Debug`/`Display`, `PartialEq`).
//!
//! ## Precision parameter
//!
//! The struct is parameterised over `R: RealField` and carries no other trait bound
//! at the type level. Methods that require additional bounds (`Display` for formatted
//! output, `Clone + Default` for `CausalTensor` construction) declare them at the
//! method site, not on the struct.

use core::marker::PhantomData;

use deep_causality_algebra::RealField;
use deep_causality_tensor::CausalTensor;

mod display;
mod getters;
mod part_eq;

/// The three orthogonal components of a discrete Hodge–Helmholtz decomposition.
///
/// Constructed by `Manifold::hodge_decompose`. Fields are private; read access is
/// through the getters in `getters`.
#[derive(Debug, Clone)]
pub struct HodgeDecomposition<R: RealField> {
    exact: CausalTensor<R>,
    co_exact: CausalTensor<R>,
    harmonic: CausalTensor<R>,
    grade: usize,
    _phantom: PhantomData<R>,
}

impl<R: RealField> HodgeDecomposition<R> {
    /// Constructs a `HodgeDecomposition` from its three orthogonal components and the
    /// grade `k` they live in.
    ///
    /// No invariants are checked at construction time. The expected invariants —
    /// orthogonality, grade-consistent dimensions, agreement with the input field —
    /// are properties of the algorithm in `Manifold::hodge_decompose`, not of the
    /// carrier. Callers constructing values directly (e.g. tests, future consumers)
    /// are responsible for supplying well-formed components.
    pub fn new(
        exact: CausalTensor<R>,
        co_exact: CausalTensor<R>,
        harmonic: CausalTensor<R>,
        grade: usize,
    ) -> Self {
        Self {
            exact,
            co_exact,
            harmonic,
            grade,
            _phantom: PhantomData,
        }
    }
}
