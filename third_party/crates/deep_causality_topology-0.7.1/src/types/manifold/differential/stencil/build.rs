/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Construction of the compiled stencil stages. Each builder replicates an
//! existing generic operator's enumeration exactly once, folding every
//! constant factor (incidence signs, diagonal Hodge entries, transport
//! averaging weights, cup-shuffle and antisymmetrization signs) into the
//! stored coefficients. The generic operators remain the equivalence
//! oracle in the test suite.

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_par::MaybeParallel;
use deep_causality_sparse::CsrMatrix;

use crate::traits::chain_complex::ChainComplex;
use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use crate::types::manifold::differential::stencil::bilinear_op::BilinearOp;
use crate::types::manifold::differential::stencil::stencil_op::StencilOp;

/// Extract the diagonal of a (diagonal) Hodge star matrix.
pub(in crate::types::manifold::differential) fn star_diag<R>(
    star: &CsrMatrix<R>,
    n: usize,
) -> Vec<R>
where
    R: RealField,
{
    let mut diag = vec![R::zero(); n];
    let ptr = star.row_indices();
    let cols = star.col_indices();
    let vals = star.values();
    for (i, d) in diag.iter_mut().enumerate() {
        for e in ptr[i]..ptr[i + 1] {
            if cols[e] == i {
                *d = vals[e];
                break;
            }
        }
    }
    diag
}

/// Compile the exterior derivative `d_k` from the cached coboundary CSR
/// (rows = (k+1)-cells, cols = k-cells, entries ±1).
pub(super) fn build_d<const D: usize, R>(complex: &LatticeComplex<D, R>, k: usize) -> StencilOp<R>
where
    R: RealField + MaybeParallel,
{
    let cob = complex.coboundary_matrix(k);
    let rows = complex.num_cells(k + 1);
    let cols = complex.num_cells(k);
    let ptr = cob.row_indices();
    let idx = cob.col_indices();
    let vals = cob.values();
    let mut entries: Vec<Vec<(usize, R)>> = Vec::with_capacity(rows);
    for r in 0..rows {
        let mut row = Vec::with_capacity(ptr[r + 1] - ptr[r]);
        for e in ptr[r]..ptr[r + 1] {
            let sign = if vals[e] >= 0 {
                R::one()
            } else {
                R::zero() - R::one()
            };
            row.push((idx[e], sign));
        }
        entries.push(row);
    }
    StencilOp::from_rows(entries, cols)
}

/// Compile the codifferential `δ_k = M_{k−1}^{-1} ∂_k M_k` with the
/// generic path's zero-mass guard folded in (a sub-tolerance mass row
/// compiles to an empty stencil row, matching the generic zero output).
pub(super) fn build_delta<const D: usize, R>(
    complex: &LatticeComplex<D, R>,
    star_k: &[R],
    star_km1: &[R],
    k: usize,
) -> StencilOp<R>
where
    R: RealField + MaybeParallel + FromPrimitive,
{
    let boundary = complex.boundary_matrix(k);
    let rows = complex.num_cells(k - 1);
    let cols = complex.num_cells(k);
    let ptr = boundary.row_indices();
    let idx = boundary.col_indices();
    let vals = boundary.values();
    let zero_tol =
        <R as FromPrimitive>::from_f64(1e-12).expect("1e-12 is representable in every RealField");

    let mut entries: Vec<Vec<(usize, R)>> = Vec::with_capacity(rows);
    for r in 0..rows {
        if star_km1[r].abs() <= zero_tol {
            entries.push(Vec::new());
            continue;
        }
        let inv_mass = R::one() / star_km1[r];
        let mut row = Vec::with_capacity(ptr[r + 1] - ptr[r]);
        for e in ptr[r]..ptr[r + 1] {
            let sign = if vals[e] >= 0 {
                R::one()
            } else {
                R::zero() - R::one()
            };
            row.push((idx[e], sign * star_k[idx[e]] * inv_mass));
        }
        entries.push(row);
    }
    StencilOp::from_rows(entries, cols)
}

/// Compile the dual→primal complement transport for source grade `k_src`
/// (the averaging gather of `interior_product`'s
/// `dual_to_primal_complement`), with an optional per-source-column
/// diagonal fold (the preceding Hodge star) and a global sign.
pub(super) fn build_transport<const D: usize, R>(
    complex: &LatticeComplex<D, R>,
    k_src: usize,
    source_diag: &[R],
    global_sign_negative: bool,
) -> StencilOp<R>
where
    R: RealField + MaybeParallel + FromPrimitive,
{
    let shape = *complex.shape();
    let periodic = *complex.periodic();
    let full_mask: u32 = if D == 32 { u32::MAX } else { (1u32 << D) - 1 };
    let rows = complex.num_cells(D - k_src);

    let mut entries: Vec<Vec<(usize, R)>> = Vec::with_capacity(rows);
    for target in complex.iter_cells(D - k_src) {
        let b_mask = target.orientation();
        let a_mask = full_mask & !b_mask;

        // ε(A, Aᶜ): inversions between source and target axes.
        let mut inversions = 0usize;
        for a in 0..D {
            if a_mask & (1 << a) != 0 {
                for b in 0..a {
                    if b_mask & (1 << b) != 0 {
                        inversions += 1;
                    }
                }
            }
        }
        let mut negate = inversions % 2 == 1;
        if global_sign_negative {
            negate = !negate;
        }

        // Collect the contributing source indices (≤ 2^D, duplicates
        // merged below for degenerate wraps on tiny periodic extents).
        let mut srcs: Vec<usize> = Vec::with_capacity(1 << D);
        for combo in 0..(1u32 << D) {
            let mut pos = *target.position();
            let mut in_range = true;
            for (d, p) in pos.iter_mut().enumerate() {
                if combo & (1 << d) == 0 {
                    continue;
                }
                if a_mask & (1 << d) != 0 {
                    if *p == 0 {
                        if periodic[d] {
                            *p = shape[d] - 1;
                        } else {
                            in_range = false;
                            break;
                        }
                    } else {
                        *p -= 1;
                    }
                } else {
                    *p += 1;
                    if *p >= shape[d] {
                        if periodic[d] {
                            *p -= shape[d];
                        } else {
                            in_range = false;
                            break;
                        }
                    }
                }
            }
            if !in_range {
                continue;
            }
            let src = LatticeCell::new(pos, a_mask);
            if let Some(i) = complex.cell_index(&src) {
                srcs.push(i);
            }
        }

        if srcs.is_empty() {
            entries.push(Vec::new());
            continue;
        }
        let count_r =
            <R as FromPrimitive>::from_usize(srcs.len()).expect("cell count lifts into RealField");
        let base = R::one() / count_r;
        let weight = if negate { R::zero() - base } else { base };

        let mut row: Vec<(usize, R)> = Vec::with_capacity(srcs.len());
        for s in srcs {
            let w = weight * source_diag[s];
            if let Some(existing) = row.iter_mut().find(|(c, _)| *c == s) {
                existing.1 += w;
            } else {
                row.push((s, w));
            }
        }
        entries.push(row);
    }
    debug_assert_eq!(entries.len(), rows);
    StencilOp::from_rows(entries, source_diag.len())
}

/// Compile the wedge `α ∧ β` for `α` of grade `a` and `β` of grade 1 into
/// bilinear triples: `½(α ∪ β + (−1)^a β ∪ α)` with the cup-shuffle signs.
pub(super) fn build_wedge_a_1<const D: usize, R>(
    complex: &LatticeComplex<D, R>,
    a: usize,
) -> BilinearOp<R>
where
    R: RealField + MaybeParallel,
{
    let shape = *complex.shape();
    let periodic = *complex.periodic();
    let out_grade = a + 1;
    let cols_a = complex.num_cells(a);
    let cols_b = complex.num_cells(1);
    let two = R::one() + R::one();
    let half = R::one() / two;
    let kl_negative = a % 2 == 1;

    let mut entries: Vec<Vec<(usize, usize, R)>> = Vec::with_capacity(complex.num_cells(out_grade));
    for q in complex.iter_cells(out_grade) {
        let axes: Vec<usize> = (0..D).filter(|i| q.orientation() & (1 << i) != 0).collect();
        let kl = out_grade;
        let mut row: Vec<(usize, usize, R)> = Vec::new();

        // One cup pass; `first_is_alpha` selects α ∪ β (|H| = a) vs
        // β ∪ α (|H| = 1), with the antisymmetrization sign on the latter.
        let mut cup_pass = |h_count: usize, first_is_alpha: bool| {
            for subset in 0..(1u32 << kl) {
                if subset.count_ones() as usize != h_count {
                    continue;
                }
                let mut inversions = 0usize;
                for i in 0..kl {
                    if subset & (1 << i) != 0 {
                        for j in 0..i {
                            if subset & (1 << j) == 0 {
                                inversions += 1;
                            }
                        }
                    }
                }
                let mut h_mask = 0u32;
                for (i, &axis) in axes.iter().enumerate() {
                    if subset & (1 << i) != 0 {
                        h_mask |= 1 << axis;
                    }
                }
                let t_mask = q.orientation() & !h_mask;

                let front = LatticeCell::new(*q.position(), h_mask);
                let mut back_pos = *q.position();
                for (i, &axis) in axes.iter().enumerate() {
                    if subset & (1 << i) != 0 {
                        back_pos[axis] += 1;
                        if periodic[axis] && back_pos[axis] >= shape[axis] {
                            back_pos[axis] -= shape[axis];
                        }
                    }
                }
                let back = LatticeCell::new(back_pos, t_mask);

                let front_idx = complex
                    .cell_index(&front)
                    .expect("front face of an existing cell is always a valid lattice cell");
                let back_idx = complex
                    .cell_index(&back)
                    .expect("back face of an existing cell is always a valid lattice cell");

                let mut c = half;
                if inversions % 2 == 1 {
                    c = R::zero() - c;
                }
                if first_is_alpha {
                    row.push((front_idx, back_idx, c));
                } else {
                    // β ∪ α term: β is the front operand, α the back; the
                    // antisymmetrization contributes (−1)^{a·1}.
                    let signed = if kl_negative { R::zero() - c } else { c };
                    row.push((back_idx, front_idx, signed));
                }
            }
        };

        cup_pass(a, true);
        cup_pass(1, false);
        entries.push(row);
    }
    BilinearOp::from_rows(entries, cols_a, cols_b)
}
