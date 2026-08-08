/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! CPU implementation of geometry operations for Manifold.
//!
//! Computes purely from the data-precision `D`: edge lengths in the metric are typed
//! `ReggeGeometry<D>` and volumes/determinants return `D`. The coordinate type `C` is
//! treated as an opaque identifier and is no longer bounded numerically here.

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

use crate::{Manifold, Simplex, SimplicialComplex, TopologyError};
use deep_causality_tensor::{CausalTensor, CausalTensorError};
use std::collections::HashMap;

impl<C, D> Manifold<SimplicialComplex<C>, D>
where
    C: RealField + FromPrimitive,
{
    /// CPU implementation of simplex volume squared calculation.
    ///
    /// Returns the volume in the **metric precision** `C` — Cayley-Menger inputs are
    /// edge lengths from the metric, and the volume lives in the same field. The
    /// manifold's data precision `D` does not participate in this computation; callers
    /// who need the volume in `D` precision are responsible for the conversion.
    pub(crate) fn simplex_volume_squared_impl(
        &self,
        simplex: &Simplex,
    ) -> Result<C, TopologyError> {
        let k = simplex.vertices.len() - 1;

        if k == 0 {
            return Ok(C::one());
        }

        let num_vertices = k + 1;
        let matrix_dim = k + 2;
        let mut cm_matrix_data = vec![C::zero(); matrix_dim * matrix_dim];

        let squared_lengths = self.get_simplex_edge_lengths_squared_impl(simplex)?;

        let one = C::one();
        for i in 1..matrix_dim {
            cm_matrix_data[i] = one;
            cm_matrix_data[i * matrix_dim] = one;
        }

        for i in 0..num_vertices {
            for j in i..num_vertices {
                let dist_sq = if i == j {
                    C::zero()
                } else {
                    let key = if simplex.vertices[i] < simplex.vertices[j] {
                        (simplex.vertices[i], simplex.vertices[j])
                    } else {
                        (simplex.vertices[j], simplex.vertices[i])
                    };
                    *squared_lengths.get(&key).ok_or_else(|| {
                        TopologyError::ManifoldError(format!("Missing edge length for {:?}", key))
                    })?
                };
                cm_matrix_data[(i + 1) * matrix_dim + (j + 1)] = dist_sq;
                cm_matrix_data[(j + 1) * matrix_dim + (i + 1)] = dist_sq;
            }
        }

        let cm_tensor = CausalTensor::new(cm_matrix_data, vec![matrix_dim, matrix_dim])?;
        let det =
            determinant_impl(&cm_tensor).map_err(|e| TopologyError::TensorError(e.to_string()))?;

        // Squared k-volume formula: vol² = (-1)^(k+1) / (2^k * (k!)^2) * det(CM)
        let mut k_fac = C::one();
        for i in 1..=k {
            k_fac *=
                <C as FromPrimitive>::from_usize(i).expect("usize is representable in RealField");
        }
        let two = <C as FromPrimitive>::from_f64(2.0).expect("2.0 is representable");
        let mut two_pow_k = C::one();
        for _ in 0..k {
            two_pow_k *= two;
        }
        let denominator = two_pow_k * k_fac * k_fac;
        let sign = if k.is_multiple_of(2) {
            -C::one()
        } else {
            C::one()
        };

        let vol_sq = (sign / denominator) * det;

        if vol_sq < C::zero() {
            Ok(C::zero())
        } else {
            Ok(vol_sq)
        }
    }

    /// CPU implementation: get all edge lengths squared for a given simplex.
    fn get_simplex_edge_lengths_squared_impl(
        &self,
        simplex: &Simplex,
    ) -> Result<HashMap<(usize, usize), C>, TopologyError> {
        let metric = self
            .metric
            .as_ref()
            .ok_or(TopologyError::ManifoldError("Metric not found".to_string()))?;

        let skeleton_1 = self
            .complex
            .skeletons
            .get(1)
            .ok_or(TopologyError::DimensionMismatch(
                "1-skeleton not found".to_string(),
            ))?;

        let mut edge_lengths = HashMap::new();

        let vertices = &simplex.vertices;
        for i in 0..vertices.len() {
            for j in (i + 1)..vertices.len() {
                let v1 = vertices[i];
                let v2 = vertices[j];

                let edge_simplex = Simplex::new(vec![v1, v2]);

                if let Some(edge_index) = skeleton_1.get_index(&edge_simplex) {
                    let length = metric.edge_lengths.get(&[edge_index]).ok_or(
                        TopologyError::IndexOutOfBounds("Edge length not found".to_string()),
                    )?;
                    edge_lengths.insert((v1, v2), (*length) * (*length));
                } else {
                    return Err(TopologyError::SimplexNotFound());
                }
            }
        }

        Ok(edge_lengths)
    }
}

/// CPU implementation of determinant using Laplace expansion.
pub(crate) fn determinant_impl<T>(matrix: &CausalTensor<T>) -> Result<T, CausalTensorError>
where
    T: RealField,
{
    let shape = matrix.shape();
    if shape.len() != 2 || shape[0] != shape[1] {
        return Err(CausalTensorError::InvalidParameter(
            "Determinant requires a square matrix".into(),
        ));
    }
    let n = shape[0];

    if n == 0 {
        return Ok(T::one());
    }
    if n == 1 {
        return Ok(matrix.as_slice()[0]);
    }
    if n == 2 {
        let m = matrix.as_slice();
        return Ok(m[0] * m[3] - m[1] * m[2]);
    }

    let mut det = T::zero();
    for j1 in 0..n {
        let sign = if j1 % 2 == 0 { T::one() } else { -T::one() };

        let mut sub_matrix_data = Vec::with_capacity((n - 1) * (n - 1));
        for i in 1..n {
            for j in 0..n {
                if j == j1 {
                    continue;
                }
                sub_matrix_data.push(*matrix.get(&[i, j]).unwrap());
            }
        }
        let sub_matrix = CausalTensor::new(sub_matrix_data, vec![n - 1, n - 1])?;
        det += sign * *matrix.get(&[0, j1]).unwrap() * determinant_impl(&sub_matrix)?;
    }

    Ok(det)
}
