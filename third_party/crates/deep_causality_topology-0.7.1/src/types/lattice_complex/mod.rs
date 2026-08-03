/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod dual_lattice_complex;
pub mod lattice_cell;
pub mod specialized;

pub use lattice_cell::LatticeCell;

use crate::traits::cell::Cell;
use crate::traits::chain_complex::ChainComplex;
use crate::traits::neighborhood::CellId;
use deep_causality_algebra::RealField;
use deep_causality_sparse::CsrMatrix;
use std::borrow::Cow;
use std::collections::HashMap;
use std::marker::PhantomData;
use std::sync::OnceLock;

/// A combinatorial cubical lattice in `D` dimensions, paired with a metric precision `R`.
///
/// `D` is the lattice dimensionality (always a compile-time constant); `R` is the
/// precision of the associated metric, threaded through to `Metric = CubicalReggeGeometry<D, R>`
/// via the `ChainComplex` impl. The combinatorial caches (`shape`, `periodic`, coboundary
/// memo) are `R`-independent — the `PhantomData<R>` field exists only to anchor the
/// metric-precision parameter. See `design.md` Decision 1 of the
/// `generalize-topology-over-realfield` change set for the rationale.
#[derive(Debug)]
pub struct LatticeComplex<const D: usize, R: RealField> {
    /// Dimensions of the lattice [L₀, L₁, ..., L_{D-1}]
    shape: [usize; D],
    /// Periodic boundary conditions per dimension
    periodic: [bool; D],
    /// Lazy memo of coboundary matrices: δ_k = (∂_{k+1})ᵀ.
    /// One `OnceLock` per grade in `0..=D`; populated on first call to `coboundary_matrix(k)`;
    /// ignored for equality. `OnceLock` (not `Mutex<HashMap>`) keeps reads lock-free after first
    /// init and lets `coboundary_matrix` return `Cow::Borrowed`, eliminating the per-call CSR
    /// clone. `Box<[OnceLock<...>]>` is `Send + Sync` for the existing
    /// `Arc<LatticeComplex<D, R>>` consumers in `gauge_field_lattice`.
    coboundary_cache: Box<[OnceLock<CsrMatrix<i8>>]>,
    /// Lazy memo of boundary matrices ∂_k, same shape and rationale as
    /// `coboundary_cache`. `codifferential` (hence every Laplacian
    /// application, hence every CG iteration) reads ∂_k; without the memo
    /// each read rebuilt the matrix from a cell-indexed `HashMap`. Slot 0
    /// is unused (∂_0 does not exist; `boundary_matrix` requires k ≥ 1).
    boundary_cache: Box<[OnceLock<CsrMatrix<i8>>]>,
    /// Anchors the metric-precision parameter `R`. Zero-sized.
    _precision: PhantomData<R>,
}

impl<const D: usize, R: RealField> Clone for LatticeComplex<D, R> {
    fn clone(&self) -> Self {
        Self {
            shape: self.shape,
            periodic: self.periodic,
            // Filled cache slots are cloned: copying a CSR is a flat
            // memcpy of its arrays, while recomputing one rebuilds the
            // grade's boundary matrix and transposes it. Callers that
            // clone a complex per operator evaluation (the DEC solver's
            // scratch manifolds, several per RK4 step) hit this path on
            // every step; the earlier reset-on-clone turned each of those
            // into a full rebuild. Unfilled slots stay lazy.
            coboundary_cache: self.coboundary_cache.clone(),
            boundary_cache: self.boundary_cache.clone(),
            _precision: PhantomData,
        }
    }
}

impl<const D: usize, R: RealField> PartialEq for LatticeComplex<D, R> {
    fn eq(&self, other: &Self) -> bool {
        self.shape == other.shape && self.periodic == other.periodic
    }
}

impl<const D: usize, R: RealField> Eq for LatticeComplex<D, R> {}

impl<const D: usize, R: RealField> LatticeComplex<D, R> {
    // --- Constructors ---

    /// Create a new lattice with given shape and boundary conditions.
    pub fn new(shape: [usize; D], periodic: [bool; D]) -> Self {
        Self {
            shape,
            periodic,
            coboundary_cache: Self::fresh_cache(),
            boundary_cache: Self::fresh_cache(),
            _precision: PhantomData,
        }
    }

    /// Build an empty per-grade coboundary cache with `D + 1` slots (one per grade `0..=D`).
    fn fresh_cache() -> Box<[OnceLock<CsrMatrix<i8>>]> {
        (0..=D)
            .map(|_| OnceLock::new())
            .collect::<Vec<_>>()
            .into_boxed_slice()
    }

    /// Create a fully periodic (toroidal) lattice.
    pub fn torus(shape: [usize; D]) -> Self {
        Self::new(shape, [true; D])
    }

    /// Create an open-boundary lattice.
    pub fn open(shape: [usize; D]) -> Self {
        Self::new(shape, [false; D])
    }

    // --- Getters ---

    /// Shape of the lattice [L₀, L₁, ..., L_{D-1}].
    pub fn shape(&self) -> &[usize; D] {
        &self.shape
    }

    /// Periodic boundary conditions per dimension.
    pub fn periodic(&self) -> &[bool; D] {
        &self.periodic
    }

    /// Dimension of the lattice (always D).
    pub const fn dim(&self) -> usize {
        D
    }

    // --- Cell Access ---

    /// Get the boundary of a k-cell as a chain of (k-1)-cells.
    /// Handles periodic boundary conditions.
    pub fn boundary(&self, cell: &LatticeCell<D>) -> Vec<(LatticeCell<D>, i8)> {
        let raw_boundary = cell.boundary();
        let mut periodic_boundary = Vec::new();

        for (term_cell, coeff) in raw_boundary {
            if let Some(wrapped_cell) = self.wrap_cell(&term_cell) {
                periodic_boundary.push((wrapped_cell, coeff));
            }
        }

        periodic_boundary
    }

    /// Wrap a cell into the lattice boundaries.
    /// Returns None if the cell is out of bounds (for open boundaries).
    fn wrap_cell(&self, cell: &LatticeCell<D>) -> Option<LatticeCell<D>> {
        let mut pos = *cell.position();

        for (i, p) in pos.iter_mut().enumerate() {
            let dim_len = self.shape[i];

            if *p >= dim_len {
                if self.periodic[i] {
                    *p %= dim_len;
                } else {
                    return None;
                }
            }
        }

        Some(LatticeCell::new(pos, cell.orientation()))
    }

    /// Iterator over all cells of a given dimension k.
    pub fn iter_cells(&self, k: usize) -> LatticeCellIterator<'_, D, R> {
        LatticeCellIterator::new(self, k)
    }

    /// Flat index of the 1-cell (edge) at `(position, axis)` in the canonical
    /// `iter_cells(1)` ordering. Used by `PerEdge` cubical Regge metrics to look up
    /// the edge length at a specific lattice edge.
    ///
    /// Ordering matches `LatticeCellIterator`: orientations with one bit set are visited
    /// in ascending numerical order (axis 0, then axis 1, …, then axis D−1); within each
    /// orientation, positions advance with axis 0 varying fastest. A position component
    /// equal to `shape[d] - 1` is only legal along the edge's own axis when that axis is
    /// non-periodic (the last column of edges wraps around on periodic axes only).
    pub(crate) fn edge_index(&self, position: [usize; D], axis: usize) -> usize {
        let target = 1u32 << axis;
        let mut idx = 0usize;

        for prior_axis in 0..axis {
            idx += self.edges_along(prior_axis);
        }

        let mut offset = 0usize;
        let mut stride = 1usize;
        for (d, &p) in position.iter().enumerate() {
            offset += p * stride;
            stride *= self.valid_positions(d, target);
        }
        idx + offset
    }

    /// Inverse of [`Self::edge_index`]: recover the `(position, axis)` of the
    /// 1-cell at flat index `edge_id`. O(D) work — closed-form decomposition
    /// of the canonical iteration ordering.
    ///
    /// Returns `None` for out-of-range `edge_id` or for axes that have no
    /// edges (e.g. a zero-extent dimension on an open lattice).
    ///
    /// Used by `CubicalReggeGeometry::regge_gradient_at_edge` to enumerate
    /// only the hinges containing a given edge, dropping the per-edge gradient
    /// cost from O(num_hinges · 2^D) to O(D · 2^D).
    pub(crate) fn edge_id_to_position_axis(&self, edge_id: usize) -> Option<([usize; D], usize)> {
        let mut count = 0usize;
        for axis in 0..D {
            let along_axis = self.edges_along(axis);
            if edge_id < count + along_axis {
                let mut local = edge_id - count;
                let target = 1u32 << axis;
                let mut position = [0usize; D];
                for (d, p) in position.iter_mut().enumerate() {
                    let vp = self.valid_positions(d, target);
                    if vp == 0 {
                        return None;
                    }
                    *p = local % vp;
                    local /= vp;
                }
                return Some((position, axis));
            }
            count += along_axis;
        }
        None
    }

    /// Number of 1-cells along a given axis on this lattice. `pub(crate)` so the cubical
    /// Regge volume / curvature modules can size `PerEdge` buffers and validate inputs.
    pub(crate) fn edges_along(&self, axis: usize) -> usize {
        let orientation = 1u32 << axis;
        let mut count = 1usize;
        for d in 0..D {
            count *= self.valid_positions(d, orientation);
        }
        count
    }

    /// Flat index of `cell` in the canonical `iter_cells(grade)` ordering —
    /// the arithmetic inverse of `LatticeCellIterator` for arbitrary grades,
    /// O(2^D + D) with no allocation. Returns `None` when the cell's
    /// position is out of range for its orientation (the open-boundary
    /// trim), mirroring exactly which cells the iterator visits.
    ///
    /// This replaces the per-call `HashMap<LatticeCell, usize>` index maps
    /// the DEC operators (wedge, interior-product transport, de Rham,
    /// sharp) previously built on every evaluation: the map construction
    /// was O(n) allocation and hashing per operator call, where the lookup
    /// itself is pure stride arithmetic on a regular lattice.
    pub(crate) fn cell_index(&self, cell: &LatticeCell<D>) -> Option<usize> {
        let o = cell.orientation();

        // Bounds check against the iterator's valid-position ranges.
        for (d, &p) in cell.position().iter().enumerate() {
            if p >= self.valid_positions(d, o) {
                return None;
            }
        }

        // Cells of the same grade with numerically smaller orientations
        // come first (orientation-major, ascending bit patterns).
        let grade = o.count_ones();
        let mut idx = 0usize;
        for prior in 0..o {
            if prior.count_ones() == grade {
                let mut count = 1usize;
                for d in 0..D {
                    count *= self.valid_positions(d, prior);
                }
                idx += count;
            }
        }

        // Within the orientation block, axis 0 varies fastest.
        let mut offset = 0usize;
        let mut stride = 1usize;
        for (d, &p) in cell.position().iter().enumerate() {
            offset += p * stride;
            stride *= self.valid_positions(d, o);
        }
        Some(idx + offset)
    }

    /// Number of valid `position[d]` values for a cell with the given `orientation`.
    /// Active non-periodic dims lose the wrap-around slice; all others use the full extent.
    pub(crate) fn valid_positions(&self, d: usize, orientation: u32) -> usize {
        let dim_len = self.shape[d];
        let is_active = (orientation & (1 << d)) != 0;
        let is_periodic = self.periodic[d];
        if is_active && !is_periodic {
            if dim_len == 0 { 0 } else { dim_len - 1 }
        } else {
            dim_len
        }
    }

    /// Top D-cubes incident to a (D−2)-hinge.
    ///
    /// Walks `boundary_matrix(D−1)` row `hinge_id` to enumerate the (D−1)-faces whose
    /// boundary contains the hinge, then walks `boundary_matrix(D)` row by row to
    /// collect every D-cube whose boundary contains one of those faces. The result is
    /// deduplicated and returned as a `Vec<CellId>` (small — at most 4 entries on a
    /// regular lattice).
    ///
    /// Returns an empty vector for `D < 2` (where (D−2)-hinges don't exist) or when
    /// `hinge_id` is out of range.
    ///
    /// # Implementation note
    ///
    /// The design note proposes routing through `coboundary_matrix(D−2)` and
    /// `coboundary_matrix(D−1)` instead. Both directions give the same incidence
    /// information; we use `boundary_matrix` because CSR storage indexes naturally
    /// by row (`O(degree)` per row slice), whereas extracting a column from the
    /// coboundary form requires an `O(nnz)` scan. Functionally equivalent; cheaper
    /// in this access pattern.
    pub fn hinge_top_cube_neighbors(&self, hinge_id: CellId) -> Vec<CellId> {
        if D < 2 {
            return Vec::new();
        }
        let num_hinges = self.num_cells(D - 2);
        if hinge_id >= num_hinges {
            return Vec::new();
        }

        let b_dm1 = self.boundary_matrix(D - 1);
        let b_d = self.boundary_matrix(D);

        let dm1_rows = b_dm1.row_indices();
        let dm1_cols = b_dm1.col_indices();
        let d_rows = b_d.row_indices();
        let d_cols = b_d.col_indices();

        let face_slice = &dm1_cols[dm1_rows[hinge_id]..dm1_rows[hinge_id + 1]];

        let mut out: Vec<CellId> = Vec::new();
        for &face in face_slice {
            let top_slice = &d_cols[d_rows[face]..d_rows[face + 1]];
            for &top in top_slice {
                if !out.contains(&top) {
                    out.push(top);
                }
            }
        }
        out
    }
}

// --- Iterator ---

pub struct LatticeCellIterator<'a, const D: usize, R: RealField> {
    lattice: &'a LatticeComplex<D, R>,
    // k is used in new() but not stored
    orientations: Vec<u32>,
    current_orientation_idx: usize,
    current_pos: [usize; D],
    done: bool,
}

impl<'a, const D: usize, R: RealField> LatticeCellIterator<'a, D, R> {
    fn new(lattice: &'a LatticeComplex<D, R>, k: usize) -> Self {
        // Generate all k-bit patterns in D bits, then drop orientations whose product of
        // valid positions across all axes is zero. Without the filter, a lattice with
        // `shape[d] == 0` along a non-periodic active axis would yield phantom cells (the
        // first position `[0; D]` is always emitted before the advance loop checks the
        // zero-extent axis), so `cells(k).count()` would not match `num_cells(k)`.
        let mut orientations = Vec::new();
        let limit: usize = 1 << D;
        for i in 0..limit {
            if i.count_ones() as usize == k {
                let orient = i as u32;
                let count: usize = (0..D).map(|d| lattice.valid_positions(d, orient)).product();
                if count > 0 {
                    orientations.push(orient);
                }
            }
        }

        let done: bool = orientations.is_empty();

        Self {
            lattice,
            orientations,
            current_orientation_idx: 0,
            current_pos: [0; D],
            done,
        }
    }
}

impl<'a, const D: usize, R: RealField> Iterator for LatticeCellIterator<'a, D, R> {
    type Item = LatticeCell<D>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }

        let orientation = self.orientations[self.current_orientation_idx];
        let cell = LatticeCell::new(self.current_pos, orientation);

        // Advance position logic...
        let mut carry = true;
        for i in 0..D {
            if carry {
                self.current_pos[i] += 1;

                let limit = self.lattice.shape[i];
                let is_active_dim = (orientation & (1 << i)) != 0;
                let is_periodic = self.lattice.periodic[i];

                let max_idx = if is_active_dim && !is_periodic {
                    if limit == 0 { 0 } else { limit - 1 }
                } else {
                    limit
                };

                if self.current_pos[i] >= max_idx {
                    self.current_pos[i] = 0;
                    carry = true;
                } else {
                    carry = false;
                }
            }
        }

        if carry {
            self.current_orientation_idx += 1;
            if self.current_orientation_idx >= self.orientations.len() {
                self.done = true;
            } else {
                self.current_pos = [0; D];
            }
        }

        Some(cell)
    }
}

impl<const D: usize, R: RealField> ChainComplex for LatticeComplex<D, R> {
    type CellType = LatticeCell<D>;
    type CellIter<'a>
        = LatticeCellIterator<'a, D, R>
    where
        Self: 'a;
    type Metric = crate::CubicalReggeGeometry<D, R>;

    fn cells(&self, k: usize) -> Self::CellIter<'_> {
        self.iter_cells(k)
    }

    fn num_cells(&self, k: usize) -> usize {
        let mut total = 0;
        let limit: usize = 1 << D;
        for i in 0..limit {
            if i.count_ones() as usize == k {
                let orientation = i as u32;
                let mut count = 1;
                for d in 0..D {
                    let dim_len = self.shape[d];
                    let is_active = (orientation & (1 << d)) != 0;
                    let is_periodic = self.periodic[d];

                    let valid_positions = if is_active && !is_periodic {
                        if dim_len == 0 { 0 } else { dim_len - 1 }
                    } else {
                        dim_len
                    };
                    count *= valid_positions;
                }
                total += count;
            }
        }
        total
    }

    fn max_dim(&self) -> usize {
        D
    }

    fn boundary_matrix(&self, k: usize) -> Cow<'_, CsrMatrix<i8>> {
        // Lazy memo, mirroring `coboundary_matrix`: ∂_k is read by
        // `codifferential` on every Laplacian application — once per CG
        // iteration in the Hodge/Leray solves — and the cell-indexed
        // HashMap construction below is far more expensive than the
        // sparse matvec it feeds.
        let slot = &self.boundary_cache[k];
        let m = slot.get_or_init(|| {
            let rows = self.num_cells(k - 1);
            let cols = self.num_cells(k);

            let mut row_map = HashMap::new();
            for (i, cell) in self.cells(k - 1).enumerate() {
                row_map.insert(cell, i);
            }

            let mut triplets = Vec::new();

            for (j, cell) in self.cells(k).enumerate() {
                let boundary = self.boundary(&cell);
                for (term_cell, coeff) in boundary {
                    if let Some(&i) = row_map.get(&term_cell) {
                        triplets.push((i, j, coeff));
                    }
                }
            }

            CsrMatrix::from_triplets(rows, cols, &triplets).unwrap_or_else(|_| CsrMatrix::new())
        });
        Cow::Borrowed(m)
    }

    fn coboundary_matrix(&self, k: usize) -> Cow<'_, CsrMatrix<i8>> {
        // Lazy memo: δ_k = (∂_{k+1})ᵀ. One OnceLock per grade in 0..=D.
        let slot = &self.coboundary_cache[k];
        let m = slot.get_or_init(|| self.boundary_matrix(k + 1).into_owned().transpose());
        Cow::Borrowed(m)
    }

    fn betti_number(&self, k: usize) -> usize {
        let all_periodic = self.periodic.iter().all(|&p| p);
        if all_periodic {
            if k > D {
                return 0;
            }
            let mut res = 1;
            for i in 0..k {
                res = res * (D - i) / (i + 1);
            }
            res
        } else {
            let p_dims = self.periodic.iter().filter(|&&p| p).count();
            if k > p_dims {
                return 0;
            }
            let mut res = 1;
            for i in 0..k {
                res = res * (p_dims - i) / (i + 1);
            }
            res
        }
    }

    fn uniform_lattice_layout(&self) -> Option<(Vec<usize>, Vec<bool>)> {
        Some((self.shape.to_vec(), self.periodic.to_vec()))
    }
}

// --- Specialized Constructors ---

impl<R: RealField> LatticeComplex<2, R> {
    pub fn square_torus(l: usize) -> Self {
        Self::new([l, l], [true, true])
    }
    pub fn square_open(l: usize) -> Self {
        Self::new([l, l], [false, false])
    }
}

impl<R: RealField> LatticeComplex<3, R> {
    pub fn cubic_torus(l: usize) -> Self {
        Self::new([l, l, l], [true, true, true])
    }
    pub fn cubic_open(l: usize) -> Self {
        Self::new([l, l, l], [false, false, false])
    }
}

impl<R: RealField> LatticeComplex<4, R> {
    pub fn hypercubic_torus(l: usize) -> Self {
        Self::new([l, l, l, l], [true, true, true, true])
    }
}

#[cfg(test)]
mod edge_index_tests {
    use super::*;

    #[test]
    fn open_2d_axis0_ordering() {
        let l: LatticeComplex<2, f64> = LatticeComplex::square_open(3);
        assert_eq!(l.edges_along(0), 6);
        assert_eq!(l.edge_index([0, 0], 0), 0);
        assert_eq!(l.edge_index([1, 0], 0), 1);
        assert_eq!(l.edge_index([0, 1], 0), 2);
        assert_eq!(l.edge_index([1, 1], 0), 3);
        assert_eq!(l.edge_index([0, 2], 0), 4);
        assert_eq!(l.edge_index([1, 2], 0), 5);
    }

    #[test]
    fn open_2d_axis1_ordering_starts_after_axis0() {
        let l: LatticeComplex<2, f64> = LatticeComplex::square_open(3);
        assert_eq!(l.edge_index([0, 0], 1), 6);
        assert_eq!(l.edge_index([1, 0], 1), 7);
        assert_eq!(l.edge_index([2, 0], 1), 8);
        assert_eq!(l.edge_index([0, 1], 1), 9);
        assert_eq!(l.edge_index([2, 1], 1), 11);
    }

    #[test]
    fn periodic_2d_includes_wraparound_edges() {
        let l: LatticeComplex<2, f64> = LatticeComplex::square_torus(3);
        assert_eq!(l.edges_along(0), 9);
        assert_eq!(l.edges_along(1), 9);
        assert_eq!(l.edge_index([0, 0], 1), 9);
        assert_eq!(l.edge_index([2, 2], 1), 17);
    }

    #[test]
    fn mixed_boundary_3d_counts() {
        let l: LatticeComplex<3, f64> = LatticeComplex::new([2, 3, 4], [true, false, true]);
        assert_eq!(l.edges_along(0), 24);
        assert_eq!(l.edges_along(1), 16);
        assert_eq!(l.edges_along(2), 24);
        assert_eq!(l.edge_index([0, 0, 0], 1), 24);
        assert_eq!(l.edge_index([0, 0, 0], 2), 40);
    }

    #[test]
    fn edge_index_matches_iter_cells_ordering_open_2d() {
        let l: LatticeComplex<2, f64> = LatticeComplex::square_open(4);
        for (i, cell) in l.iter_cells(1).enumerate() {
            let axis = cell.orientation().trailing_zeros() as usize;
            assert_eq!(
                l.edge_index(*cell.position(), axis),
                i,
                "mismatch at edge {i} (position {:?}, axis {axis})",
                cell.position(),
            );
        }
    }

    #[test]
    fn edge_index_matches_iter_cells_ordering_periodic_3d() {
        let l: LatticeComplex<3, f64> = LatticeComplex::cubic_torus(3);
        for (i, cell) in l.iter_cells(1).enumerate() {
            let axis = cell.orientation().trailing_zeros() as usize;
            assert_eq!(l.edge_index(*cell.position(), axis), i);
        }
    }
}
