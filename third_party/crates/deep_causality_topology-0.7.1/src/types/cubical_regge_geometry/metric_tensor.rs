/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Per-cell metric tensor for `CubicalReggeGeometry<D, R, S>` — Phase R5.3.
//!
//! On an axis-aligned cubical lattice, the local metric tensor at every cell
//! is diagonal. The diagonal entries are the squared edge lengths along each
//! axis, with sign determined by the signature marker `S`:
//!
//! - [`Euclidean`]: every diagonal entry is positive (`+L_axis²`).
//! - [`Lorentzian`]: each entry flagged timelike in `timelike_axes` carries a
//!   negative sign (`−L_axis²`), all others positive — East-Coast convention.
//!
//! The returned `CausalTensor<R>` has shape `[D, D]` and zero off-diagonal
//! entries.

use super::{CubicalReggeGeometry, SignatureMarker};
use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

impl<const D: usize, R, S> CubicalReggeGeometry<D, R, S>
where
    R: RealField + FromPrimitive,
    S: SignatureMarker,
{
    /// Local metric tensor `g_{μν}` at the given cell, encoded as a `CausalTensor`
    /// of shape `[D, D]`.
    ///
    /// Diagonal entry `g_{ii} = ±L_i²` where:
    /// - `L_i` is the edge length along axis `i` at the cell's position.
    /// - The sign is `−` iff axis `i` is timelike (per `timelike_axes` and the
    ///   `Lorentzian` marker); `+` otherwise.
    ///
    /// Off-diagonal entries are zero (axis-aligned cubical assumption).
    pub fn metric_tensor_at(
        &self,
        complex: &LatticeComplex<D, R>,
        cell: &LatticeCell<D>,
    ) -> CausalTensor<R> {
        let position = *cell.position();
        // Per-axis sign comes from the `deep_causality_metric` `Metric` value
        // synthesised by `self.signature()`. `Metric::sign_of_sq(axis)` returns
        // `+1`, `-1`, or `0` per the East-Coast Lorentzian / Custom convention.
        // This centralises signature truth in the metric crate instead of a
        // hand-rolled `if is_timelike` check; future PGA / Custom signatures
        // are supported by construction.
        let metric = self.signature();

        let mut data = vec![R::zero(); D * D];
        for axis in 0..D {
            let length = self.axis_length_at_position(complex, position, axis);
            let l_sq = length * length;
            let entry = match metric.sign_of_sq(axis) {
                1 => l_sq,
                -1 => -l_sq,
                _ => R::zero(),
            };
            data[axis * D + axis] = entry;
        }
        CausalTensor::new(data, vec![D, D]).expect("D × D metric tensor allocation")
    }
}
