/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Shared test fixtures for the cubical Regge calculus core (R1–R3).
//!
//! These small open / periodic lattices and matching metrics keep the property tests
//! under `tests/types/cubical_regge_geometry/` concise. Living in `src/utils_tests/` is
//! required so Bazel can reach them during testing (see `AGENTS.md` test layout notes).

use crate::types::cubical_regge_geometry::CubicalReggeGeometry;
use crate::types::lattice_complex::LatticeComplex;

/// 3×3 open-boundary square lattice with `R = f64` precision.
pub fn open_square_3() -> LatticeComplex<2, f64> {
    LatticeComplex::square_open(3)
}

/// 3×3 periodic (torus) square lattice with `R = f64` precision.
pub fn periodic_square_3() -> LatticeComplex<2, f64> {
    LatticeComplex::square_torus(3)
}

/// 3×3×3 open-boundary cubic lattice with `R = f64` precision.
pub fn open_cube_3() -> LatticeComplex<3, f64> {
    LatticeComplex::cubic_open(3)
}

/// 3×3×3 periodic cubic lattice with `R = f64` precision.
pub fn periodic_cube_3() -> LatticeComplex<3, f64> {
    LatticeComplex::cubic_torus(3)
}

/// Unit-edge cubical Regge geometry in dimension `D`, `R = f64`.
pub fn unit_geometry<const D: usize>() -> CubicalReggeGeometry<D, f64> {
    CubicalReggeGeometry::unit()
}

/// `PerAxis` geometry with the given axis lengths, `R = f64`.
pub fn per_axis_geometry<const D: usize>(lengths: [f64; D]) -> CubicalReggeGeometry<D, f64> {
    CubicalReggeGeometry::per_axis(lengths)
}

/// `PerEdge` geometry on `complex` where every edge along axis `a` has length `lengths[a]`.
/// Reproduces a `PerAxis` configuration via the per-edge buffer — useful for cross-checking
/// the per-edge code path against the per-axis closed form.
pub fn per_edge_uniform_per_axis<const D: usize>(
    complex: &LatticeComplex<D, f64>,
    lengths: [f64; D],
) -> CubicalReggeGeometry<D, f64> {
    let total: usize = (0..D).map(|axis| complex.edges_along(axis)).sum();
    let mut buf = Vec::with_capacity(total);
    for (axis, &length) in lengths.iter().enumerate() {
        let n = complex.edges_along(axis);
        for _ in 0..n {
            buf.push(length);
        }
    }
    CubicalReggeGeometry::from_edge_lengths(buf)
}
