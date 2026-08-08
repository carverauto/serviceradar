/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Cubical backend for the `HasHodgeStar<R>` capability trait — Phase R4.3.
//!
//! Computes the discrete Hodge ⋆ on grade-`k` forms over a `LatticeComplex<D, R>` as
//! a square diagonal `num_cells(k) × num_cells(k)` sparse matrix, following the
//! FEEC/DEC mass-matrix convention used by the existing simplicial path
//! (`ReggeGeometry<R>::hodge_star_operators`): the matrix acts multiplicatively on
//! k-form coefficients, with each diagonal entry equal to the dual-/primal-cell
//! volume ratio for that cell.
//!
//! # The closed form
//!
//! For an axis-aligned cubical k-cell at position `p` with orientation bitmask `o`
//! (k bits set), the dual (D−k)-cell has the complementary orientation `~o &
//! ((1<<D)−1)`. Under the four edge-length uniformity tiers:
//!
//! - **`UnitEdge`** — every primal and dual volume is `1`, so the Hodge ⋆ is the
//!   identity matrix at every grade `k ∈ [0, D]`.
//! - **`Uniform { length }`** — primal vol = `length^k`, dual vol = `length^(D-k)`,
//!   diagonal entry = `length^(D-2k)`. Same value for every k-cell at the given
//!   grade — the matrix is a scalar multiple of the identity.
//! - **`PerAxis { lengths }`** — primal vol = product of `lengths[a]` for `a` in
//!   the orientation bits, dual vol = product of `lengths[a]` for `a` in the
//!   complementary bits, diagonal entry = dual / primal. Varies per cell only if
//!   the lengths differ between axes.
//! - **`PerEdge`** — fully general per-edge metric. The dual (D−k)-cell of a
//!   primal k-cell at position `p` with active axes `A` is constructed by joining
//!   the centers of the 2^(D−k) "corner" top cubes incident to σ. Its volume is
//!   the average over those corners of the product of complement-axis edge lengths
//!   at the corresponding shifted positions:
//!
//!   ```text
//!   |σ*| = (1 / |valid_masks|) · Σ_{m ∈ {0,1}^(D−k) valid}
//!            ∏_{c ∈ A^c}  L(p − m_c · e_c, axis = c)
//!   ```
//!
//!   where `m_c ∈ {0, 1}` selects whether the edge along axis `c` is the one
//!   leaving `p` in the positive direction (`m_c = 0`, edge at position `p`) or
//!   arriving at `p` from the negative direction (`m_c = 1`, edge at position
//!   `p − e_c`). On open lattices, masks that reference out-of-bounds edges are
//!   dropped from both the sum and the divisor; on periodic lattices every mask
//!   is valid and the divisor is exactly `2^(D−k)`.
//!
//!   Verification: when all edge lengths are equal to a single value `L`, the
//!   formula reduces to the `Uniform` closed form `L^(D−2k)` at every cell on a
//!   periodic lattice — checked as a property test in
//!   `tests/types/cubical_regge_geometry/has_hodge_star_tests.rs`. The
//!   simplicial-vs-cubical cross-check on the unit square is the
//!   `add-hodge-decomposition` H3 test (it requires the field-level Hodge
//!   decomposition surface, not yet shipped).
//!
//! # Verified expectations (design.md Decision 4)
//!
//! 2D `PerAxis` with axes `[a, b]`:
//! - ⋆_0 entry = `a · b` (vertex → 2-cube ratio).
//! - ⋆_1 entries = `b/a` for edges along axis 0, `a/b` for edges along axis 1.
//! - ⋆_2 entry = `1 / (a · b)` (2-cube → vertex ratio).

use super::{CubicalReggeGeometry, EdgeLengths, SignatureMarker};
use crate::TopologyError;
use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::cut_cell::CutCellRegistry;
use crate::types::lattice_complex::LatticeCell;
use crate::types::lattice_complex::LatticeComplex;
use deep_causality_algebra::RealField;
use deep_causality_metric::Metric;
use deep_causality_num::FromPrimitive;
use deep_causality_sparse::CsrMatrix;
use std::borrow::Cow;

/// Count how many of a primal k-cell's active axes are timelike according to
/// the supplied `Metric` value. The `Metric` is the authoritative source of
/// per-axis sign convention (East-Coast Lorentzian, Custom per-axis,
/// Euclidean, etc.) — see `deep_causality_metric::Metric::sign_of_sq`.
fn timelike_axes_in_orientation<const D: usize>(orientation: u32, metric: &Metric) -> usize {
    (0..D)
        .filter(|&axis| (orientation & (1u32 << axis)) != 0 && metric.sign_of_sq(axis) == -1)
        .count()
}

impl<const D: usize, R, S> CubicalReggeGeometry<D, R, S>
where
    R: RealField + FromPrimitive,
    S: SignatureMarker,
{
    /// Build the diagonal Hodge ⋆ at grade `k`, with the per-cell dual clip supplied by
    /// `clip`. The standard star ([`HasHodgeStar::hodge_star_matrix`]) passes the integer
    /// axis-aligned wall clip ([`axis_boundary_clip`]); the cut-cell star
    /// ([`Self::cut_hodge_star_matrix`]) passes the continuous wetted fraction. Both share
    /// this one body so the cut star cannot drift from the standard star.
    fn build_star_diagonal(
        &self,
        complex: &LatticeComplex<D, R>,
        k: usize,
        clip: &dyn Fn(&LatticeCell<D>) -> R,
    ) -> CsrMatrix<R> {
        let n = complex.num_cells(k);
        let mut triplets: Vec<(usize, usize, R)> = Vec::with_capacity(n);

        // Per-cell sign factor `(−1)^t` where t = timelike axes in the primal cell's active
        // dimensions; Euclidean ⇒ always `+1` (the `SignatureMarker::sign_factor` static
        // dispatch lets the optimizer elide the metric work entirely on `S = Euclidean`).
        let metric = if S::is_lorentzian() {
            Some(self.signature())
        } else {
            None
        };
        let cell_sign = |orientation: u32| -> R {
            match &metric {
                None => R::one(),
                Some(m) => S::sign_factor::<R>(timelike_axes_in_orientation::<D>(orientation, m)),
            }
        };

        match &self.edge_lengths {
            EdgeLengths::UnitEdge => {
                // Identity on the interior; boundary duals clip.
                for (i, cell) in complex.cells(k).enumerate() {
                    triplets.push((i, i, cell_sign(cell.orientation()) * clip(&cell)));
                }
            }
            EdgeLengths::Uniform { length } => {
                // Diagonal magnitude = length^(D - 2k). Per-cell sign from metric.
                let magnitude = pow_signed(*length, (D as isize) - 2 * (k as isize));
                for (i, cell) in complex.cells(k).enumerate() {
                    triplets.push((
                        i,
                        i,
                        cell_sign(cell.orientation()) * magnitude * clip(&cell),
                    ));
                }
            }
            EdgeLengths::PerAxis { lengths } => {
                // Per-cell diagonal: depends on which axes the cell occupies.
                let all_axes_mask: u32 = if D >= 32 { u32::MAX } else { (1u32 << D) - 1 };
                for (i, cell) in complex.cells(k).enumerate() {
                    let orientation = cell.orientation();
                    let complement = (!orientation) & all_axes_mask;

                    let mut primal = R::one();
                    let mut dual = R::one();
                    for (axis, length) in lengths.iter().enumerate() {
                        let bit = 1u32 << axis;
                        if (orientation & bit) != 0 {
                            primal *= *length;
                        }
                        if (complement & bit) != 0 {
                            dual *= *length;
                        }
                    }
                    triplets.push((i, i, cell_sign(orientation) * (dual / primal) * clip(&cell)));
                }
            }
            EdgeLengths::PerEdge { lengths } => {
                // R4.4 per-edge implementation. Formula in module doc above.
                let all_axes_mask: u32 = if D >= 32 { u32::MAX } else { (1u32 << D) - 1 };
                for (i, cell) in complex.cells(k).enumerate() {
                    let orientation = cell.orientation();
                    let complement = (!orientation) & all_axes_mask;
                    let position = *cell.position();

                    // Primal volume = product over orientation-axis edge lengths.
                    let mut primal = R::one();
                    for axis in 0..D {
                        if (orientation & (1u32 << axis)) != 0 {
                            let idx = complex.edge_index(position, axis);
                            primal *= lengths[idx];
                        }
                    }

                    // Dual volume = average over 2^(D-k) corner masks of the product of
                    // complement-axis edge lengths at the shifted positions.
                    let complement_axes: Vec<usize> = (0..D)
                        .filter(|&a| (complement & (1u32 << a)) != 0)
                        .collect();
                    let num_complement = complement_axes.len();
                    let num_masks = 1u32 << num_complement;

                    let mut dual_sum = R::zero();
                    let mut valid_count: usize = 0;
                    for mask_bits in 0..num_masks {
                        if let Some(prod) = per_edge_corner_product(
                            complex,
                            lengths,
                            &position,
                            &complement_axes,
                            mask_bits,
                        ) {
                            dual_sum += prod;
                            valid_count += 1;
                        }
                    }

                    if valid_count == 0 {
                        continue;
                    }
                    let divisor = <R as FromPrimitive>::from_usize(valid_count)
                        .expect("usize fits in every RealField");
                    let dual = dual_sum / divisor;
                    triplets.push((i, i, cell_sign(orientation) * (dual / primal) * clip(&cell)));
                }
            }
        }

        CsrMatrix::from_triplets(n, n, &triplets)
            .expect("Diagonal triplets always satisfy CSR validity for square shape.")
    }

    /// Cut-cell-aware Hodge ⋆ at grade `k`: identical to
    /// [`HasHodgeStar::hodge_star_matrix`] except the per-cell dual clip is the **continuous
    /// wetted fraction** ([`CutCellRegistry::dual_fluid_fraction`]) instead of the integer
    /// `2^{-b}` wall clip (`axis_boundary_clip`).
    ///
    /// With an **empty** registry on the same lattice this returns the standard star to
    /// rounding — the cut clip reduces to the boundary clip — which is the Stage-3
    /// equivalence the cut substrate must satisfy. Built uncached: the cut star is
    /// registry-specific and is not memoised in the geometry's per-lattice star cache.
    pub fn cut_hodge_star_matrix(
        &self,
        complex: &LatticeComplex<D, R>,
        registry: &CutCellRegistry<D, R>,
        k: usize,
    ) -> Result<CsrMatrix<R>, TopologyError> {
        if k > D {
            return Ok(CsrMatrix::new());
        }
        Ok(self.build_star_diagonal(complex, k, &|cell| {
            registry.dual_fluid_fraction(complex, cell)
        }))
    }
}

impl<const D: usize, R, S> HasHodgeStar<R> for CubicalReggeGeometry<D, R, S>
where
    R: RealField + FromPrimitive,
    S: SignatureMarker,
{
    type Complex = LatticeComplex<D, R>;

    fn hodge_star_matrix<'a>(
        &'a self,
        complex: &'a Self::Complex,
        k: usize,
    ) -> Result<Cow<'a, CsrMatrix<R>>, TopologyError> {
        // Out-of-range grade: return an empty 0x0 matrix. Mirrors the simplicial
        // `Manifold::hodge_star` behaviour for k > max_dim.
        if k > D {
            return Ok(Cow::Owned(CsrMatrix::new()));
        }

        // The diagonal ⋆ is immutable for this (geometry, lattice) pair, so build it at most
        // once per grade and serve it borrowed from the memo; on a fingerprint mismatch (a
        // metric reused across differently-shaped complexes) fall through to an uncached
        // owned build. The per-cell clip is the integer axis-aligned wall clip unless a
        // cut-cell registry is attached, in which case it is that registry's continuous wetted
        // fraction — so an immersed body flows through every star consumer (stencils, Leray,
        // codifferential) transparently. An empty registry reduces to the wall clip exactly.
        let build = || match &self.cut_registry {
            Some(registry) => self.build_star_diagonal(complex, k, &|cell| {
                registry.dual_fluid_fraction(complex, cell)
            }),
            None => self.build_star_diagonal(complex, k, &|cell| axis_boundary_clip(complex, cell)),
        };

        let shape = *complex.shape();
        let periodic = *complex.periodic();
        if let Some(slots) = self.star_cache.slots(&shape, &periodic) {
            return Ok(Cow::Borrowed(slots[k].get_or_init(build)));
        }
        Ok(Cow::Owned(build()))
    }

    fn uniform_axis_spacings(&self) -> Option<Vec<R>> {
        // The spectral Poisson eigenvalues assume a positive-definite
        // diagonal Hodge ⋆; Lorentzian sign factors break that, so only
        // the Euclidean signature qualifies. Per-edge geometries have no
        // per-axis spacing and stay on CG.
        if S::is_lorentzian() {
            return None;
        }
        self.axis_lengths().map(|lengths| lengths.to_vec())
    }
}

/// The Stage-3 axis-aligned wall clip `2^{-b}`: a primal cell's dual halves at each open-axis
/// boundary incidence (`b` = number of such incidences) — wall faces halve, wall edges
/// quarter, 3D wall corners eighth. Periodic axes never clip. This is the integer special
/// case the cut-cell [`CutCellRegistry::dual_fluid_fraction`] generalises to a continuous
/// wetted fraction.
pub(crate) fn axis_boundary_clip<const D: usize, R: RealField>(
    complex: &LatticeComplex<D, R>,
    cell: &LatticeCell<D>,
) -> R {
    let lattice_shape = *complex.shape();
    let lattice_periodic = *complex.periodic();
    let two = R::one() + R::one();
    let mut factor = R::one();
    for a in 0..D {
        let active = cell.orientation() & (1u32 << a) != 0;
        if active || lattice_periodic[a] {
            continue;
        }
        let pos = cell.position()[a];
        if pos == 0 || pos + 1 == lattice_shape[a] {
            factor /= two;
        }
    }
    factor
}

/// For a primal k-cell at `position` with complement axes `complement_axes`, compute
/// the product of edge lengths along those axes at the shifted "corner" position
/// selected by `mask_bits`. Bit `i` of `mask_bits` selects between `m_c = 0` (edge
/// starting at `position` going positive in axis `c`) and `m_c = 1` (edge ending at
/// `position` arriving from negative).
///
/// Returns `None` if any required edge is out of bounds on an open lattice; periodic
/// axes wrap around per the lattice convention so every mask is valid for them.
fn per_edge_corner_product<const D: usize, R>(
    complex: &LatticeComplex<D, R>,
    lengths: &[R],
    position: &[usize; D],
    complement_axes: &[usize],
    mask_bits: u32,
) -> Option<R>
where
    R: RealField,
{
    let shape = complex.shape();
    let periodic = complex.periodic();

    let mut product = R::one();
    for (bit_idx, &axis) in complement_axes.iter().enumerate() {
        let m_c = (mask_bits >> bit_idx) & 1;
        // Resolve the position of the edge along `axis`.
        let dim_len = shape[axis];
        let is_periodic = periodic[axis];

        // Edge along axis exists at positions 0..valid_positions; here for an
        // edge-along-axis-c cell, valid_positions = dim_len if periodic, else
        // dim_len - 1 (the wraparound slice).
        let max_edge_pos = if is_periodic {
            dim_len
        } else if dim_len == 0 {
            return None;
        } else {
            dim_len - 1
        };

        let edge_pos_axis = if m_c == 0 {
            // Edge starts at position[axis], goes to position[axis] + 1.
            if position[axis] >= max_edge_pos {
                return None;
            }
            position[axis]
        } else if position[axis] == 0 {
            if is_periodic {
                // Wrap to the last edge slot, which goes from dim_len-1 back to 0.
                dim_len - 1
            } else {
                return None;
            }
        } else {
            position[axis] - 1
        };

        let mut edge_position = *position;
        edge_position[axis] = edge_pos_axis;
        let idx = complex.edge_index(edge_position, axis);
        if idx >= lengths.len() {
            return None;
        }
        product *= lengths[idx];
    }
    Some(product)
}

/// Raise `base` to a signed integer power. `base^0 = R::one()`; negative exponents
/// are computed as the reciprocal of the positive power. Used for the `Uniform`
/// tier where the Hodge ⋆ scalar is `length^(D - 2k)`, which is negative for `k > D/2`.
fn pow_signed<R>(base: R, exp: isize) -> R
where
    R: RealField,
{
    if exp == 0 {
        return R::one();
    }
    let n = exp.unsigned_abs();
    let mut acc = R::one();
    for _ in 0..n {
        acc *= base;
    }
    if exp < 0 { R::one() / acc } else { acc }
}
