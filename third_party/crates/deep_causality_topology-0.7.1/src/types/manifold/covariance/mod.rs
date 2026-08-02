/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of covariance analysis for Manifold fields.

use crate::{Manifold, SimplicialComplex, TopologyError};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::{CausalTensor, CausalTensorStatsExt};

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField,
    D: RealField + FromPrimitive,
{
    /// CPU implementation of covariance matrix computation.
    ///
    /// The field data is a single scalar variable sampled across simplices, so
    /// this returns a `1 × 1` matrix holding the sample variance (`ddof = 1`).
    /// The variance itself is delegated to the shared
    /// [`CausalTensorStatsExt::sample_covariance`] primitive — the field is
    /// reshaped into an `n × 1` observation matrix — so the numerical definition
    /// is identical to the rest of the stack and not duplicated here.
    pub(crate) fn covariance_matrix_impl(&self) -> Result<Vec<Vec<D>>, TopologyError> {
        let data = self.data.as_slice();
        let n = data.len();

        if n < 2 {
            // Sample variance uses Bessel's correction (divide by n - 1). Single-sample
            // and empty inputs leave that divisor at 0 or negative; the statistic is
            // undefined either way.
            return Err(TopologyError::InvalidInput(format!(
                "Cannot compute covariance from {n} sample(s); need at least 2"
            )));
        }

        // Treat the field as `n` observations of a single variable.
        let observations = CausalTensor::from_slice(data, &[n, 1]);
        let cov = observations
            .sample_covariance()
            .map_err(|e| TopologyError::InvalidInput(format!("covariance failed: {e}")))?;
        let variance = *cov.get(&[0, 0]).ok_or_else(|| {
            TopologyError::InvalidInput("covariance matrix is missing its (0,0) entry".to_string())
        })?;

        Ok(vec![vec![variance]])
    }

    /// CPU implementation of eigenvalue decomposition for covariance analysis.
    ///
    /// Returns eigenvalues sorted in descending order.
    pub(crate) fn eigen_covariance_impl(&self) -> Result<Vec<D>, TopologyError> {
        let cov = self.covariance_matrix_impl()?;

        if cov.len() == 1 && cov[0].len() == 1 {
            return Ok(vec![cov[0][0]]);
        }

        Err(TopologyError::InvalidInput(
            "Multi-dimensional covariance eigenvalues not yet implemented".to_string(),
        ))
    }
}
