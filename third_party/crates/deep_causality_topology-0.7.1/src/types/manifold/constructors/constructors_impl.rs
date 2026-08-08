/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of Manifold constructors.

use crate::{ReggeGeometry, SimplicialComplex, TopologyError};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use super::super::{Manifold, utils};

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField + FromPrimitive,
{
    /// CPU implementation of Manifold constructor.
    pub(crate) fn new_impl(
        complex: SimplicialComplex<C>,
        data: CausalTensor<D>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        // Validation: Check data size matches complex
        let expected_size: usize = complex.skeletons.iter().map(|s| s.simplices.len()).sum();
        if data.len() != expected_size {
            return Err(TopologyError::InvalidInput(
                "Data size must match total number of simplices in complex".to_string(),
            ));
        }

        if cursor >= data.len() {
            return Err(TopologyError::IndexOutOfBounds(
                "Initial cursor out of bounds for Manifold".to_string(),
            ));
        }

        if !Self::check_is_manifold_impl(&complex) {
            return Err(TopologyError::ManifoldError(
                "SimplicialComplex does not satisfy manifold properties".to_string(),
            ));
        }

        Ok(Self {
            complex,
            data,
            metric: None,
            cursor,
        })
    }

    /// CPU implementation of Manifold constructor with metric.
    pub(crate) fn with_metric_impl(
        complex: SimplicialComplex<C>,
        data: CausalTensor<D>,
        metric: Option<ReggeGeometry<C>>,
        cursor: usize,
    ) -> Result<Self, TopologyError> {
        // Validation: Check data size matches complex
        let expected_size: usize = complex.skeletons.iter().map(|s| s.simplices.len()).sum();
        if data.len() != expected_size {
            return Err(TopologyError::InvalidInput(
                "Data size must match total number of simplices in complex".to_string(),
            ));
        }

        if let Some(ref regge) = metric {
            if let Some(skeleton_1) = complex.skeletons.get(1) {
                if skeleton_1.simplices.len() != regge.edge_lengths.len() {
                    return Err(TopologyError::InvalidInput(
                        "Metric edge_lengths size must match number of 1-simplices".to_string(),
                    ));
                }
            } else if !regge.edge_lengths.is_empty() {
                return Err(TopologyError::InvalidInput(
                    "Metric provided but complex has no 1-simplices".to_string(),
                ));
            }
        }

        if cursor >= data.len() {
            return Err(TopologyError::IndexOutOfBounds(
                "Initial cursor out of bounds for Manifold".to_string(),
            ));
        }

        if !Self::check_is_manifold_impl(&complex) {
            return Err(TopologyError::ManifoldError(
                "SimplicialComplex does not satisfy manifold properties".to_string(),
            ));
        }

        // Validate the Hodge ⋆ surface once at the DEC entry point. Attaching
        // a metric is the contract point where the caller commits to DEC
        // semantics; the lazy build is forced here so downstream differential
        // operators (codifferential, hodge_star, laplacian, hodge_decompose)
        // can rely on `OnceLock` being populated and never encounter a build
        // failure at access time. Failures surface here as
        // `TopologyError::PointCloudError` instead of as a panic downstream.
        if metric.is_some() {
            let _ = complex.hodge_star_operators()?;
        }

        Ok(Self {
            complex,
            data,
            metric,
            cursor,
        })
    }

    /// CPU implementation: check if complex satisfies manifold properties.
    fn check_is_manifold_impl(complex: &SimplicialComplex<C>) -> bool {
        // Basic check: complex must have at least one skeleton
        if complex.skeletons.is_empty() {
            return false;
        }

        // For a proper manifold, we need non-trivial structure
        let num_vertices = complex
            .skeletons
            .first()
            .map(|s| s.simplices.len())
            .unwrap_or(0);
        if num_vertices == 0 {
            return false;
        }

        // A manifold must be oriented
        if !utils::is_oriented(complex) {
            return false;
        }

        // A manifold must satisfy the link condition
        if !utils::satisfies_link_condition(complex) {
            return false;
        }

        true
    }
}

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField + FromPrimitive,
    D: Clone,
{
    /// CPU implementation of shallow clone.
    pub(crate) fn clone_shallow_impl(manifold: &Self) -> Self {
        Manifold {
            complex: manifold.complex.clone(),
            data: manifold.data.clone(),
            metric: manifold.metric.clone(),
            cursor: 0,
        }
    }
}
