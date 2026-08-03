/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::fmt;
use std::fmt::Display;

use deep_causality_multivector::CausalMultiVectorError;
use deep_causality_tensor::CausalTensorError;

//  Inner Error variant
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TopologyErrorEnum {
    /// Error indicating a simplex was not found in the complex or skeleton.
    SimplexNotFound,
    /// Error indicating a dimension mismatch in operations.
    DimensionMismatch(String),
    /// Error indicating an invalid operation for a given grade (e.g., boundary of 0-chain).
    InvalidGradeOperation(String),
    /// Error indicating an index is out of bounds for a data structure.
    IndexOutOfBounds(String),
    /// Error during tensor creation or manipulation.
    TensorError(String),
    /// Error specific to PointCloud operations.
    PointCloudError(String),
    /// Error specific to Graph operations.
    GraphError(String),
    /// Error specific to Hypergraph operations.
    HypergraphError(String),
    /// Error specific to Manifold operations or validation.
    ManifoldError(String),
    /// Error during multivector operations.
    MultivectorError(String),
    /// Error indicating a malformed or invalid input structure.
    InvalidInput(String),
    /// Error indicating an invalid metric calculation or configuration.
    InvalidMetric(String),
    /// Error specific to GaugeField shape or configuration issues.
    GaugeFieldError(String),
    /// Error specific to LatticeGaugeField operations.
    LatticeGaugeError(String),
    /// Error from a Hodge–Helmholtz decomposition failure: non-convergence of the
    /// iterative solve, grade out of range, field-dimension mismatch, or a missing
    /// metric. The carried message names the discriminating cause and any relevant
    /// numerical detail (iteration count, residual, grade, dimensions). The detail
    /// is formatted at the error-construction site to keep the public error surface
    /// free of the field-precision type parameter `R`.
    HodgeDecompositionFailed(String),
    /// General catch-all error for other topological issues.
    GenericError(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopologyError(pub TopologyErrorEnum);

impl Display for TopologyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            TopologyErrorEnum::SimplexNotFound => write!(f, "Simplex not found"),
            TopologyErrorEnum::DimensionMismatch(msg) => write!(f, "Dimension mismatch: {}", msg),
            TopologyErrorEnum::InvalidGradeOperation(msg) => {
                write!(f, "Invalid grade operation: {}", msg)
            }
            TopologyErrorEnum::IndexOutOfBounds(msg) => write!(f, "Index out of bounds: {}", msg),
            TopologyErrorEnum::TensorError(msg) => write!(f, "Tensor error: {}", msg),
            TopologyErrorEnum::PointCloudError(msg) => write!(f, "PointCloud error: {}", msg),
            TopologyErrorEnum::GraphError(msg) => write!(f, "Graph error: {}", msg),
            TopologyErrorEnum::HypergraphError(msg) => write!(f, "Hypergraph error: {}", msg),
            TopologyErrorEnum::ManifoldError(msg) => write!(f, "Manifold error: {}", msg),
            TopologyErrorEnum::MultivectorError(msg) => write!(f, "Multivector error: {}", msg),
            TopologyErrorEnum::InvalidInput(msg) => write!(f, "Invalid input: {}", msg),
            TopologyErrorEnum::InvalidMetric(msg) => write!(f, "Invalid metric: {}", msg),
            TopologyErrorEnum::GaugeFieldError(msg) => write!(f, "GaugeField error: {}", msg),
            TopologyErrorEnum::LatticeGaugeError(msg) => {
                write!(f, "LatticeGaugeField error: {}", msg)
            }
            TopologyErrorEnum::HodgeDecompositionFailed(msg) => {
                write!(f, "Hodge decomposition failed: {}", msg)
            }
            TopologyErrorEnum::GenericError(msg) => write!(f, "Topology error: {}", msg),
        }
    }
}

impl std::error::Error for TopologyError {}

impl From<CausalTensorError> for TopologyError {
    fn from(err: CausalTensorError) -> Self {
        TopologyError(TopologyErrorEnum::TensorError(err.to_string()))
    }
}

impl From<CausalMultiVectorError> for TopologyError {
    fn from(err: CausalMultiVectorError) -> Self {
        TopologyError(TopologyErrorEnum::MultivectorError(err.to_string()))
    }
}

// Constructors for convenient migration
impl TopologyError {
    pub fn new(variant: TopologyErrorEnum) -> Self {
        Self(variant)
    }

    #[allow(non_snake_case)]
    pub fn SimplexNotFound() -> Self {
        Self(TopologyErrorEnum::SimplexNotFound)
    }

    #[allow(non_snake_case)]
    pub fn DimensionMismatch<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::DimensionMismatch(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn InvalidGradeOperation<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::InvalidGradeOperation(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn IndexOutOfBounds<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::IndexOutOfBounds(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn TensorError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::TensorError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn PointCloudError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::PointCloudError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn GraphError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::GraphError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn HypergraphError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::HypergraphError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn ManifoldError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::ManifoldError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn MultivectorError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::MultivectorError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn InvalidInput<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::InvalidInput(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn InvalidMetric<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::InvalidMetric(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn GaugeFieldError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::GaugeFieldError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn LatticeGaugeError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::LatticeGaugeError(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn HodgeDecompositionFailed<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::HodgeDecompositionFailed(msg.into()))
    }

    #[allow(non_snake_case)]
    pub fn GenericError<S: Into<String>>(msg: S) -> Self {
        Self(TopologyErrorEnum::GenericError(msg.into()))
    }
}
