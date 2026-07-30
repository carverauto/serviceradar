/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Topology type for discrete fields on simplicial complexes.

use crate::SimplicialComplex;
use deep_causality_tensor::CausalTensor;
use std::sync::Arc;

// Submodule declarations (folder-based)
mod api;
mod clone;
mod constructors;
mod display;
mod getters;

mod ops;

// Re-export public API

/// Represents a discrete field defined on the k-skeleton.
///
/// (e.g., Temperature on Vertices, Magnetic Flux on Faces).
#[derive(Clone, Debug)]
pub struct Topology<T> {
    /// Shared reference to the underlying mesh.
    pub(crate) complex: Arc<SimplicialComplex<T>>,
    /// The dimension of the simplices this data lives on.
    pub(crate) grade: usize,
    /// The values (CausalTensor is essentially a dense vector here).
    pub(crate) data: CausalTensor<T>,
    /// The Focus (Cursor) for Comonadic extraction.
    pub(crate) cursor: usize,
}
