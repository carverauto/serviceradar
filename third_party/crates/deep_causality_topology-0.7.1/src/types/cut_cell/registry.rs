/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Sparse registry of cut cells over a lattice, plus the cut-aware volume / dual-clip
//! accessors that ride the existing `CubicalReggeGeometry` dispatch.

use super::carrier::CutCell;
use super::cut_face_constraint::{CutConstraintKind, CutFaceConstraint};
use crate::traits::neighborhood::CellId;
use crate::types::cubical_regge_geometry::CubicalReggeGeometry;
use crate::types::cubical_regge_geometry::SignatureMarker;
use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use deep_causality_algebra::RealField;
use std::collections::HashMap;

/// A sparse map from a top `D`-cell's index (in the lattice's `iter_cells(D)` ordering) to
/// its [`CutCell`] overlay.
///
/// Only cells the immersed surface intersects (cut) or that fall inside the body (solid)
/// are stored; every top cell absent from the registry is a full fluid cell on the existing
/// uniform fast path. The registry is therefore sized to the boundary, not the volume
/// (design D1). It carries no metric of its own — the accessors take the geometry and
/// lattice so a single registry composes with any `CubicalReggeGeometry` tier (unit,
/// uniform, per-axis, graded `PerEdge`).
#[derive(Debug, Clone, PartialEq)]
pub struct CutCellRegistry<const D: usize, R: RealField> {
    cells: HashMap<CellId, CutCell<D, R>>,
    /// Small-cut-cell stabilization floor (cell-merging): the minimum fluid fraction a free
    /// cell or edge dual is allowed before it is inflated to this value. `None` = unstabilized.
    /// See [`Self::with_cell_merging`].
    min_fluid_fraction: Option<R>,
    /// Opt-in: visit cut cells in ascending `CellId` order (rather than `HashMap` order) in
    /// [`Self::iter`] and [`Self::cut_face_constraints`]. The default `HashMap` hasher
    /// (`RandomState`/SipHash) reseeds per process, so its iteration — hence the cut-face
    /// constraint row order, hence the constrained projection's floating-point summation order —
    /// varies run to run (a ~1e-11 roundoff drift). Enabling this makes the cut-cell solver
    /// bit-reproducible. `false` = unchanged `HashMap` order. See [`Self::with_deterministic_order`].
    deterministic_order: bool,
}

impl<const D: usize, R: RealField> Default for CutCellRegistry<D, R> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const D: usize, R: RealField> CutCellRegistry<D, R> {
    /// An empty registry — every cell is full fluid.
    pub fn new() -> Self {
        Self {
            cells: HashMap::new(),
            min_fluid_fraction: None,
            deterministic_order: false,
        }
    }

    /// Build a registry from a precomputed `top-cell-index -> CutCell` map.
    pub fn from_map(cells: HashMap<CellId, CutCell<D, R>>) -> Self {
        Self {
            cells,
            min_fluid_fraction: None,
            deterministic_order: false,
        }
    }

    /// Enable **cell-merging small-cut-cell stabilization** with floor `min_fraction ∈ (0, 1]`
    /// (the CFD Stage-4 B1/B2 stabilizer).
    ///
    /// Arbitrarily small cut cells give arbitrarily small Hodge-star masses, and the viscous
    /// stencil's `1/mass` factor then makes the explicit operator stiff enough to violate the
    /// CFL bound for any usable time step — the canonical cut-cell hazard. This floors every
    /// *free* (non-zero) clipped volume and dual fraction at `min_fraction`, i.e. a vanishing
    /// cut cell borrows enough volume from the body to reach the floor — the volume-fraction
    /// realisation of Berger–Helzel cell-merging. It is the star-native stabilizer for this DEC
    /// solver: the exterior derivative is combinatorial and untouched, so discrete conservation
    /// and the Leray projection's exact divergence-freeness are preserved; only an `O(min_fraction)`
    /// geometric error is introduced, localised to the floored cells (the accepted
    /// accuracy-for-stability trade). Fully-dry (`0`) interior-solid cells are left at `0` —
    /// they are pinned by the immersed no-slip set and dropped from the dynamics.
    ///
    /// Flux-redistribution (Colella–Graves–Modiano) is the other classic option but needs a
    /// per-cell *conservative update* to redistribute, which this projected-rate RK4 formulation
    /// does not expose; cell-merging is selected on that architectural fit (design D4).
    pub fn with_cell_merging(mut self, min_fraction: R) -> Self {
        self.min_fluid_fraction = Some(min_fraction);
        self
    }

    /// The active cell-merging floor, if stabilization is enabled.
    pub fn cell_merging_floor(&self) -> Option<R> {
        self.min_fluid_fraction
    }

    /// Opt into **deterministic iteration order**: cut cells are visited in ascending `CellId`
    /// order by [`Self::iter`] and [`Self::cut_face_constraints`], rather than the per-process
    /// randomised `HashMap` order. This makes the cut-cell constrained projection bit-reproducible
    /// run to run; the difference it removes is otherwise pure floating-point reduction-order
    /// roundoff (the divergence residual is unaffected). Default off, so existing behaviour is
    /// unchanged unless explicitly enabled. The flag rides through `clone`/`with_cell_merging`.
    pub fn with_deterministic_order(mut self) -> Self {
        self.deterministic_order = true;
        self
    }

    /// `(CellId, &CutCell)` pairs in iteration order: ascending `CellId` when
    /// [`Self::with_deterministic_order`] is set, otherwise raw `HashMap` order (unchanged default).
    fn ordered_pairs(&self) -> Vec<(&CellId, &CutCell<D, R>)> {
        let mut pairs: Vec<(&CellId, &CutCell<D, R>)> = self.cells.iter().collect();
        if self.deterministic_order {
            pairs.sort_unstable_by_key(|(id, _)| **id);
        }
        pairs
    }

    /// Record `cut` for the top cell at index `cell_id` (in `iter_cells(D)` ordering),
    /// returning any previous entry.
    pub fn insert(&mut self, cell_id: CellId, cut: CutCell<D, R>) -> Option<CutCell<D, R>> {
        self.cells.insert(cell_id, cut)
    }

    /// Number of recorded (cut + solid) cells. Bounded by the immersed-boundary size.
    pub fn len(&self) -> usize {
        self.cells.len()
    }

    /// `true` iff no cells are recorded (the whole domain is fluid).
    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    /// The recorded [`CutCell`] for the top cell at index `cell_id`, or `None` (full fluid).
    pub fn get(&self, cell_id: CellId) -> Option<&CutCell<D, R>> {
        self.cells.get(&cell_id)
    }

    /// Iterate over `(top-cell-index, &CutCell)` pairs. Order is ascending `CellId` when
    /// [`Self::with_deterministic_order`] is set, otherwise unspecified `HashMap` order.
    pub fn iter(&self) -> impl Iterator<Item = (&CellId, &CutCell<D, R>)> {
        self.ordered_pairs().into_iter()
    }
}

impl<const D: usize, R: RealField> CutCellRegistry<D, R> {
    /// Cut-aware `k`-cell volume (A3). For a registered top `D`-cell this returns the
    /// clipped fluid volume; for every other cell it falls through to the geometry's
    /// existing `cell_volume` fast path. This is the volume override the Hodge-star
    /// dispatch consumes — the fractional-aperture generalisation of the Stage-3 wall clip.
    pub fn clipped_cell_volume<S: SignatureMarker>(
        &self,
        geom: &CubicalReggeGeometry<D, R, S>,
        complex: &LatticeComplex<D, R>,
        cell: &LatticeCell<D>,
    ) -> R {
        if cell.cell_dim() == D
            && let Some(idx) = complex.cell_index(cell)
            && let Some(cut) = self.cells.get(&idx)
        {
            let v = cut.fluid_volume();
            // Cell-merging floor: a free (non-zero) clipped volume is inflated to
            // `min_fraction · full`, so a vanishing cut cell cannot collapse the time step.
            if let Some(a) = self.min_fluid_fraction {
                let floor = a * cut.full_volume();
                if v > R::zero() && v < floor {
                    return floor;
                }
            }
            return v;
        }
        geom.cell_volume(complex, cell)
    }

    /// The fluid fraction of a top cell's volume in `[0, 1]`: the registered cut/solid
    /// fraction, or `1` for an unregistered fluid cell. The continuous generalisation of
    /// "is this cell inside the domain" that the dual clip averages over.
    pub fn top_cell_fluid_fraction(
        &self,
        complex: &LatticeComplex<D, R>,
        top_base: [usize; D],
    ) -> R {
        let all_axes_mask: u32 = if D >= 32 { u32::MAX } else { (1u32 << D) - 1 };
        let cell = LatticeCell::new(top_base, all_axes_mask);
        match complex
            .cell_index(&cell)
            .and_then(|idx| self.cells.get(&idx))
        {
            Some(cut) => cut.volume_fraction(),
            None => R::one(),
        }
    }

    /// The edge indices (in `iter_cells(1)` order) that an **immersed no-slip / no-penetration**
    /// wall constrains to zero: every edge incident to at least one `Solid` top cell (B4).
    ///
    /// This pins the body interior (no flow inside the solid) and the fluid↔solid interface
    /// (zero tangential velocity = no-slip, and zero normal flux = no-penetration), the
    /// staircase immersed boundary. `Cut` cells are left carrying flow — their partial blockage
    /// is already represented by the cut Hodge star ([`Self::dual_fluid_fraction`]); resolving
    /// no-slip on the sub-cell cut face itself (aperture-weighted) is a later refinement. With
    /// the immersed surface modelled as solid cells coincident with a wall, this reproduces the
    /// Stage-3 wall-tangential set, so it composes with the existing no-slip machinery. The
    /// result is sorted and deduplicated.
    pub fn solid_incident_edges(&self, complex: &LatticeComplex<D, R>) -> Vec<usize> {
        let shape = complex.shape();
        let periodic = complex.periodic();
        let mut out: Vec<usize> = Vec::new();

        for (idx, cell) in complex.iter_cells(1).enumerate() {
            let a = cell.orientation().trailing_zeros() as usize;
            let p = *cell.position();
            // Perpendicular axes select the 2^{D-1} top cubes sharing this edge; the edge's own
            // axis fixes base[a] = p[a] (the cube spans p[a]..p[a]+1 along a).
            let perp: Vec<usize> = (0..D).filter(|&c| c != a).collect();
            let num_masks = 1u32 << perp.len();

            let mut pinned = false;
            'masks: for mask_bits in 0..num_masks {
                let mut base = p;
                for (bit_idx, &c) in perp.iter().enumerate() {
                    let dim_len = shape[c];
                    if dim_len == 0 {
                        continue 'masks;
                    }
                    let m_c = (mask_bits >> bit_idx) & 1;
                    base[c] = if m_c == 0 {
                        // Cube on the + side of the edge along axis c.
                        if periodic[c] {
                            p[c] % dim_len
                        } else if p[c] >= dim_len - 1 {
                            continue 'masks;
                        } else {
                            p[c]
                        }
                    } else if p[c] == 0 {
                        // Cube on the − side.
                        if periodic[c] {
                            dim_len - 1
                        } else {
                            continue 'masks;
                        }
                    } else {
                        p[c] - 1
                    };
                }
                if self.top_cell_is_solid(complex, base) {
                    pinned = true;
                    break;
                }
            }
            if pinned {
                out.push(idx);
            }
        }
        out
    }

    /// The **aperture-resolved** immersed no-slip / no-penetration constraint rows of every `Cut`
    /// cell (the smooth replacement for the staircase [`Self::solid_incident_edges`]).
    ///
    /// For each `Cut` cell this derives the wall condition at the *wetted cut face* rather than at
    /// the staircase edge ring: the cell's velocity is reconstructed per axis as an
    /// **aperture-weighted average** of the cell's edges parallel to that axis, and the
    /// reconstruction is contracted with the cell's local wall frame to produce
    /// `[`CutConstraintKind::NoPenetration`]` (`n̂ · u_face = 0`, the area-weighted fragment outward
    /// normal) and `D − 1` `[`CutConstraintKind::Tangential`]` (`t̂ · u_face = 0`) rows. The
    /// orthonormal frame keeps the rows independent (full column rank), so the generalized
    /// constrained projector's KKT system stays solvable; the binary single-edge pin is the
    /// unit-weight, single-entry special case (design Decision 2, Lever A).
    ///
    /// Aperture weighting: a parallel edge sitting at a perpendicular face corner is weighted by
    /// the product of that corner's per-axis face apertures, normalised so the row's weights sum to
    /// one; an edge bounded only by dry faces drops out. On a fully-wetted cut (every aperture `1`)
    /// the weights reduce to the uniform cell-centre average. Full `Fluid` and full `Solid` cells
    /// (no fragments / not `Cut`) contribute nothing here — a `Solid` cell's zero-interior pin is
    /// the staircase path's job (it has no wetted face). The `target` is `0` (static body); a
    /// nonzero target is the documented hook for a prescribed (moving) wall velocity.
    pub fn cut_face_constraints(
        &self,
        complex: &LatticeComplex<D, R>,
    ) -> Vec<CutFaceConstraint<R>> {
        let mut rows: Vec<CutFaceConstraint<R>> = Vec::new();
        // Resolve a `CellId` to its base position once (the registry stores no position).
        let cells: Vec<LatticeCell<D>> = complex.iter_cells(D).collect();

        for (&cell_id, cut) in self.ordered_pairs() {
            if !cut.class().is_cut() {
                continue;
            }
            let fragments = cut.fragments();
            if fragments.is_empty() {
                continue;
            }
            // Area-weighted outward normal and total wetted area.
            let mut area_total = R::zero();
            let mut normal_acc = [R::zero(); D];
            for f in fragments {
                let a = f.area();
                area_total += a;
                let n = f.outward_normal();
                for (d, acc) in normal_acc.iter_mut().enumerate() {
                    *acc += a * n[d];
                }
            }
            if area_total <= R::zero() {
                continue;
            }
            let mut norm_sq = R::zero();
            for &c in normal_acc.iter() {
                norm_sq += c * c;
            }
            if norm_sq <= R::zero() {
                continue;
            }
            let inv_norm = R::one() / norm_sq.sqrt();
            let mut n_hat = [R::zero(); D];
            for (d, nh) in n_hat.iter_mut().enumerate() {
                *nh = normal_acc[d] * inv_norm;
            }

            let base = *cells[cell_id].position();
            let recon = self.axis_reconstruction(complex, cut, &base);

            rows.push(constraint_row(
                &recon,
                &n_hat,
                area_total,
                CutConstraintKind::NoPenetration,
            ));
            for t_hat in wall_tangents(&n_hat) {
                rows.push(constraint_row(
                    &recon,
                    &t_hat,
                    area_total,
                    CutConstraintKind::Tangential,
                ));
            }
        }
        rows
    }

    /// Per-axis aperture-weighted reconstruction of a cut cell's velocity component: for each axis
    /// `i`, the `2^{D−1}` edges of the cell parallel to `i`, each tagged with the product of its
    /// perpendicular face apertures, normalised to sum to one (uniform fall-back if every weight is
    /// zero). The row coefficients of the no-slip / no-penetration constraints.
    fn axis_reconstruction(
        &self,
        complex: &LatticeComplex<D, R>,
        cut: &CutCell<D, R>,
        base: &[usize; D],
    ) -> [Vec<(usize, R)>; D] {
        let apertures = cut.apertures();
        core::array::from_fn(|i| {
            let perp: Vec<usize> = (0..D).filter(|&c| c != i).collect();
            let num_corners = 1usize << perp.len();
            let mut weighted: Vec<(usize, R)> = Vec::with_capacity(num_corners);
            let mut weight_sum = R::zero();
            for corner in 0..num_corners {
                let mut q = *base;
                let mut w = R::one();
                for (bit, &c) in perp.iter().enumerate() {
                    let side = (corner >> bit) & 1;
                    q[c] = base[c] + side;
                    w *= apertures[c][side];
                }
                let edge = complex.edge_index(q, i);
                weighted.push((edge, w));
                weight_sum += w;
            }
            if weight_sum > R::zero() {
                for (_, w) in weighted.iter_mut() {
                    *w /= weight_sum;
                }
                // An edge bounded only by dry faces carries zero weight; drop it from the row.
                weighted.retain(|(_, w)| *w != R::zero());
            } else {
                let mut count = R::zero();
                for _ in 0..num_corners {
                    count += R::one();
                }
                let uniform = R::one() / count;
                for (_, w) in weighted.iter_mut() {
                    *w = uniform;
                }
            }
            weighted
        })
    }

    /// `true` iff the top cell with base `top_base` is recorded `Solid` in this registry.
    fn top_cell_is_solid(&self, complex: &LatticeComplex<D, R>, top_base: [usize; D]) -> bool {
        let all_axes_mask: u32 = if D >= 32 { u32::MAX } else { (1u32 << D) - 1 };
        let cell = LatticeCell::new(top_base, all_axes_mask);
        complex
            .cell_index(&cell)
            .and_then(|idx| self.cells.get(&idx))
            .is_some_and(|cut| cut.class().is_solid())
    }

    /// Cut-aware dual clip factor for a `k`-cell (A3, A6): the fraction of the cell's dual
    /// `(D−k)`-cell that lies in the fluid, in `[0, 1]`.
    ///
    /// The dual of a primal `k`-cell is assembled from the `2^{D−k}` top cubes incident to
    /// it (one per choice of `±` side along each complement axis), exactly as in the
    /// per-edge Hodge-star dual construction. This averages those incident cubes' fluid
    /// fractions over the in-bounds corners. It **generalises the Stage-3 integer boundary
    /// clip**: when the immersed surface is an axis-aligned plane coincident with a wall,
    /// the outside cubes are solid (fraction `0`) and the inside cubes fluid (fraction `1`),
    /// so a `b`-fold wall incidence yields exactly `2^{-b}` — the `boundary_clip` value. On
    /// an empty registry every cube is fluid and the factor is `1` (no clip).
    pub fn dual_fluid_fraction(&self, complex: &LatticeComplex<D, R>, cell: &LatticeCell<D>) -> R {
        let orientation = cell.orientation();
        let position = *cell.position();
        let complement_axes: Vec<usize> = (0..D)
            .filter(|&a| (orientation & (1u32 << a)) == 0)
            .collect();
        let num_complement = complement_axes.len();
        let num_masks = 1u32 << num_complement;

        let shape = complex.shape();
        let periodic = complex.periodic();

        // Sum the fluid fraction over ALL 2^{D−k} dual corners; an out-of-bounds corner on
        // an open axis is outside the domain (a wall incidence) and contributes 0. Dividing
        // by the full corner count — not the survivor count — is what reproduces the integer
        // 2^{-b} boundary clip: b walls drop 2^{D−k}·(1 − 2^{-b}) corners to zero.
        let mut sum = R::zero();
        // Whether this edge's dual touches the immersed body (a registered cut/solid corner).
        // The cell-merging floor applies only to body-adjacent edges, so the legitimate
        // out-of-bounds wall clip (e.g. a 2^{-b} corner on a real wall) is never inflated.
        let mut touches_body = false;
        for mask_bits in 0..num_masks {
            // Resolve the base position of the incident top cube for this corner.
            let mut base = position;
            let mut in_bounds = true;
            for (bit_idx, &axis) in complement_axes.iter().enumerate() {
                let dim_len = shape[axis];
                if dim_len == 0 {
                    in_bounds = false;
                    break;
                }
                // Top cubes have every axis active: valid base range is 0..dim_len-1 on an
                // open axis, 0..dim_len (with wrap) on a periodic axis.
                let m_c = (mask_bits >> bit_idx) & 1;
                let b = if m_c == 0 {
                    // Cube on the + side: base = position[axis].
                    if periodic[axis] {
                        position[axis] % dim_len
                    } else if position[axis] >= dim_len - 1 {
                        in_bounds = false;
                        break;
                    } else {
                        position[axis]
                    }
                } else if position[axis] == 0 {
                    // Cube on the − side: base = position[axis] − 1.
                    if periodic[axis] {
                        dim_len - 1
                    } else {
                        in_bounds = false;
                        break;
                    }
                } else {
                    position[axis] - 1
                };
                base[axis] = b;
            }
            if in_bounds {
                let frac = self.top_cell_fluid_fraction(complex, base);
                // An unregistered fluid corner reports exactly 1; anything less is a registered
                // cut/solid corner, i.e. the body.
                if frac < R::one() {
                    touches_body = true;
                }
                sum += frac;
            }
        }

        let mut divisor = R::zero();
        for _ in 0..num_masks {
            divisor += R::one();
        }
        let fraction = sum / divisor;

        // Cell-merging floor: a free (non-zero) body-adjacent dual fraction is inflated to
        // `min_fraction`, so a sliver edge dual cannot collapse the time step. A fully-dry (`0`)
        // edge stays `0` — it is interior-solid, pinned by the no-slip set and dropped from the
        // dynamics. Pure wall edges (`touches_body == false`) keep their exact `2^{-b}` clip.
        if let Some(a) = self.min_fluid_fraction
            && touches_body
            && fraction > R::zero()
            && fraction < a
        {
            return a;
        }
        fraction
    }
}

/// Contract a per-axis reconstruction with a wall-frame direction into one sparse constraint row
/// `Σ dir_i · (aperture-weighted u_i) = 0`. Axes with a zero direction component drop out.
fn constraint_row<const D: usize, R: RealField>(
    recon: &[Vec<(usize, R)>; D],
    dir: &[R; D],
    row_weight: R,
    kind: CutConstraintKind,
) -> CutFaceConstraint<R> {
    let mut entries: Vec<(usize, R)> = Vec::new();
    for (i, &d_i) in dir.iter().enumerate() {
        if d_i == R::zero() {
            continue;
        }
        for &(edge, w) in recon[i].iter() {
            entries.push((edge, d_i * w));
        }
    }
    CutFaceConstraint::new(entries, R::zero(), row_weight, kind)
}

/// The `D − 1` orthonormal wall tangents complementing a unit normal `n̂`: Gram–Schmidt over the
/// standard basis, skipping directions that collapse against the normal or earlier tangents. For
/// `D = 2` this is the single in-plane perpendicular; for `D = 3`, two tangents spanning the wall.
fn wall_tangents<const D: usize, R: RealField>(n_hat: &[R; D]) -> Vec<[R; D]> {
    let mut tangents: Vec<[R; D]> = Vec::new();
    for axis in 0..D {
        if tangents.len() == D - 1 {
            break;
        }
        let mut v = [R::zero(); D];
        v[axis] = R::one();
        // Remove the normal component.
        let mut dot_n = R::zero();
        for d in 0..D {
            dot_n += v[d] * n_hat[d];
        }
        for d in 0..D {
            v[d] -= dot_n * n_hat[d];
        }
        // Remove components along already-accepted tangents.
        for t in tangents.iter() {
            let mut dot_t = R::zero();
            for d in 0..D {
                dot_t += v[d] * t[d];
            }
            for d in 0..D {
                v[d] -= dot_t * t[d];
            }
        }
        let mut norm_sq = R::zero();
        for &c in v.iter() {
            norm_sq += c * c;
        }
        // Keep only well-conditioned tangents (cancellation leaves a near-zero residual for the
        // basis axis most aligned with the normal / a prior tangent).
        if norm_sq > R::epsilon() {
            let inv = R::one() / norm_sq.sqrt();
            for c in v.iter_mut() {
                *c *= inv;
            }
            tangents.push(v);
        }
    }
    tangents
}
