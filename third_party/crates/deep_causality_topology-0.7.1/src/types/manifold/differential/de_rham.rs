/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The de Rham map (♭) and sharp map (♯): lawful transfer between
//! vertex-sampled vector fields and edge 1-form cochains on cubical lattices.
//!
//! * **De Rham (♭)**: a vector field sampled at vertices (layout: `D`
//!   components per vertex, vertex-major, axis-fastest — index
//!   `vertex * D + axis`) becomes an edge cochain by approximating the line
//!   integral along each oriented edge with the trapezoid rule
//!   (`u♭(e) = ½(u_a(p) + u_a(p + e_a)) · len(e)` for an edge along axis `a`),
//!   which is second-order accurate and *exact* for fields with linear
//!   components (hence exact on constant fields and on gradients of linear
//!   potentials — the orientation pin). Callers holding exact line integrals
//!   use [`Manifold::de_rham_from_integrals`] instead.
//! * **Sharp (♯)**: an edge cochain becomes a vertex vector field by
//!   metric-weighted averaging over the incident edges per axis
//!   (`u_a(v) = mean(ω(e)/len(e))` over the up-to-two `a`-edges incident to
//!   `v`, wrapped on periodic axes, trimmed-and-renormalized at open
//!   boundaries).
//!
//! The pair is a structure-preserving correspondence — an isomorphism *up to
//! discretization order* (exact on constants; `O(h²)` on smooth fields) — and
//! is encoded in the Tier-2 iso witness vocabulary by the
//! `extensions::iso_de_rham::DeRhamSharpIso` witness (witness-pattern code
//! lives under `extensions/` per crate convention).
//! Edge orientation matches `exterior_derivative` (low corner → high corner
//! along the edge's axis), pinned by the fundamental-theorem-of-calculus test.

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use crate::errors::topology_error::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use deep_causality_par::MaybeParallel;

use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use crate::types::manifold::Manifold;
#[cfg(feature = "parallel")]
use rayon::prelude::*;

impl<const D: usize, R> Manifold<LatticeComplex<D, R>, R>
where
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + core::fmt::Debug,
{
    /// De Rham map (♭): vertex-sampled vector field → edge 1-form, by the
    /// trapezoid-rule line integral along each edge. See the module doc for
    /// the input layout and accuracy contract.
    ///
    /// # Errors
    /// * `TopologyError::DimensionMismatch` when the input length is not
    ///   `D × num_cells(0)`.
    /// * `TopologyError::InvalidInput` when the manifold has no metric (edge
    ///   lengths are metric data).
    pub fn de_rham(
        &self,
        vertex_vectors: &CausalTensor<R>,
    ) -> Result<CausalTensor<R>, TopologyError> {
        let complex = &self.complex;
        let n0 = complex.num_cells(0);

        if vertex_vectors.len() != D * n0 {
            return Err(TopologyError::DimensionMismatch(format!(
                "de_rham input: expected {} values (D = {D} components × {} vertices), got {}",
                D * n0,
                n0,
                vertex_vectors.len()
            )));
        }
        let metric = self.metric.as_ref().ok_or_else(|| {
            TopologyError::InvalidInput(
                "de_rham requires a metric (edge lengths); construct the manifold with a metric"
                    .to_string(),
            )
        })?;

        let shape = *complex.shape();
        let periodic = *complex.periodic();
        let vals = vertex_vectors.as_slice();
        let two = R::one() + R::one();

        // Per-edge trapezoid integral: read-only over the samples and the
        // vertex map, so the edges are independent — the loop fans out over
        // Rayon under the `parallel` feature.
        let per_edge = |edge: LatticeCell<D>| {
            let axis = edge.orientation().trailing_zeros() as usize;
            let low = *edge.position();
            let mut high = low;
            high[axis] += 1;
            if periodic[axis] && high[axis] >= shape[axis] {
                high[axis] -= shape[axis];
            }

            let i_low = complex
                .cell_index(&LatticeCell::new(low, 0))
                .expect("edge endpoints are valid vertices");
            let i_high = complex
                .cell_index(&LatticeCell::new(high, 0))
                .expect("edge endpoints are valid vertices");
            let avg = (vals[i_low * D + axis] + vals[i_high * D + axis]) / two;
            avg * metric.cell_volume(complex, &edge)
        };

        // Thresholded: tiny lattices lose more to fork-join overhead than
        // the trapezoid arithmetic gains.
        #[cfg(feature = "parallel")]
        let out: Vec<R> = if complex.num_cells(1) >= 1 << 14 {
            let edges: Vec<LatticeCell<D>> = complex.iter_cells(1).collect();
            edges.into_par_iter().map(per_edge).collect()
        } else {
            complex.iter_cells(1).map(per_edge).collect()
        };
        #[cfg(not(feature = "parallel"))]
        let out: Vec<R> = complex.iter_cells(1).map(per_edge).collect();

        let len = out.len();
        Ok(CausalTensor::new(out, vec![len])
            .expect("de_rham output tensor allocation cannot fail for a 1-D shape"))
    }

    /// De Rham map, exact-integral entry point: the caller supplies the exact
    /// line integral of the vector field along each edge (canonical
    /// `iter_cells(1)` ordering, orientation low → high corner). This is a
    /// validating wrapper — the values *are* the cochain.
    ///
    /// # Errors
    /// * `TopologyError::DimensionMismatch` when the input length is not
    ///   `num_cells(1)`.
    pub fn de_rham_from_integrals(
        &self,
        edge_integrals: &CausalTensor<R>,
    ) -> Result<CausalTensor<R>, TopologyError> {
        let n1 = self.complex.num_cells(1);
        if edge_integrals.len() != n1 {
            return Err(TopologyError::DimensionMismatch(format!(
                "de_rham_from_integrals: expected {} edge integrals, got {}",
                n1,
                edge_integrals.len()
            )));
        }
        Ok(
            CausalTensor::new(edge_integrals.as_slice().to_vec(), vec![n1])
                .expect("de_rham output tensor allocation cannot fail for a 1-D shape"),
        )
    }

    /// Sharp map (♯): edge 1-form → vertex-sampled vector field (layout:
    /// `vertex * D + axis`), by metric-weighted averaging of the incident
    /// edges per axis. See the module doc.
    ///
    /// # Errors
    /// * `TopologyError::DimensionMismatch` when the input length is not
    ///   `num_cells(1)`.
    /// * `TopologyError::InvalidInput` when the manifold has no metric.
    pub fn sharp(&self, edge_cochain: &CausalTensor<R>) -> Result<CausalTensor<R>, TopologyError> {
        let complex = &self.complex;
        let n0 = complex.num_cells(0);
        let n1 = complex.num_cells(1);

        if edge_cochain.len() != n1 {
            return Err(TopologyError::DimensionMismatch(format!(
                "sharp input: expected {} grade-1 coefficients, got {}",
                n1,
                edge_cochain.len()
            )));
        }
        let metric = self.metric.as_ref().ok_or_else(|| {
            TopologyError::InvalidInput(
                "sharp requires a metric (edge lengths); construct the manifold with a metric"
                    .to_string(),
            )
        })?;

        let shape = *complex.shape();
        let periodic = *complex.periodic();
        let vals = edge_cochain.as_slice();

        // Per-vertex averaging: read-only over the cochain and the edge
        // map, so the vertices are independent — the loop fans out over
        // Rayon under the `parallel` feature. Each vertex yields its D
        // axis components in canonical `vertex * D + axis` order.
        let per_vertex = |vertex: LatticeCell<D>| -> [R; D] {
            let v_pos = *vertex.position();
            core::array::from_fn(|axis| {
                let mut acc = R::zero();
                let mut count = 0usize;

                // Outgoing edge (v, axis): exists unless v sits on the high
                // open boundary of that axis.
                let outgoing = LatticeCell::new(v_pos, 1 << axis);
                if let Some(ei) = complex.cell_index(&outgoing) {
                    acc += vals[ei] / metric.cell_volume(complex, &outgoing);
                    count += 1;
                }

                // Incoming edge (v − e_axis, axis), wrapped on periodic axes;
                // trimmed at the low open boundary.
                let mut in_pos = v_pos;
                let incoming_exists = if in_pos[axis] == 0 {
                    if periodic[axis] {
                        in_pos[axis] = shape[axis] - 1;
                        true
                    } else {
                        false
                    }
                } else {
                    in_pos[axis] -= 1;
                    true
                };
                if incoming_exists {
                    let incoming = LatticeCell::new(in_pos, 1 << axis);
                    if let Some(ei) = complex.cell_index(&incoming) {
                        acc += vals[ei] / metric.cell_volume(complex, &incoming);
                        count += 1;
                    }
                }

                if count > 0 {
                    let count_r = <R as FromPrimitive>::from_usize(count)
                        .expect("incident edge count lifts into RealField");
                    acc / count_r
                } else {
                    R::zero()
                }
            })
        };

        #[cfg(feature = "parallel")]
        let out: Vec<R> = {
            let vertices: Vec<LatticeCell<D>> = complex.iter_cells(0).collect();
            vertices.into_par_iter().flat_map_iter(per_vertex).collect()
        };
        #[cfg(not(feature = "parallel"))]
        let out: Vec<R> = complex.iter_cells(0).flat_map(per_vertex).collect();

        let _ = n0;
        let len = out.len();
        Ok(CausalTensor::new(out, vec![len])
            .expect("sharp output tensor allocation cannot fail for a 1-D shape"))
    }
}
