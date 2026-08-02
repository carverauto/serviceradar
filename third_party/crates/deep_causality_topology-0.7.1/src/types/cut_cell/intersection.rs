/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Building cut cells and registries from analytic primitives, via the exact closed-form
//! clipping in [`super::geometry`].

use super::carrier::CutCell;
use super::cut_face_fragment::CutFaceFragment;
use super::geometry::{
    box_halfspace_cross_area, box_halfspace_solid_volume, circle_in_rect_arc_len,
    rect_disk_solid_area, rmax, rmin,
};
use super::primitive::Primitive;
use super::registry::CutCellRegistry;
use crate::TopologyError;
use crate::types::cubical_regge_geometry::{CubicalReggeGeometry, SignatureMarker};
use crate::types::lattice_complex::LatticeComplex;
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;

/// Length of `[seg_lo, seg_hi]` covered by the disk's chord at a fixed perpendicular
/// coordinate: the disk spans `[perp_center − h, perp_center + h]` along the segment axis,
/// where `h = sqrt(r² − (face_coord − fixed_center)²)`.
fn disk_chord_overlap<R: RealField>(
    face_coord: R,
    fixed_center: R,
    seg_lo: R,
    seg_hi: R,
    seg_center: R,
    r: R,
) -> R {
    let d = face_coord - fixed_center;
    let h2 = r * r - d * d;
    if h2 <= R::zero() {
        return R::zero();
    }
    let h = h2.sqrt();
    let lo = rmax(seg_center - h, seg_lo);
    let hi = rmin(seg_center + h, seg_hi);
    rmax(hi - lo, R::zero())
}

impl<const D: usize, R: RealField + FromPrimitive> CutCell<D, R> {
    /// Classify and clip the axis-aligned box `[lo, hi]` against `primitive`, returning the
    /// [`CutCell`] overlay (or `Fluid` / `Solid` for an uncut box). All volumes and areas are
    /// physical measures. Returns an error for an unsupported primitive/dimension combination
    /// (e.g. a 3D ball — deferred per design D3).
    pub fn from_box(
        primitive: &Primitive<D, R>,
        lo: [R; D],
        hi: [R; D],
    ) -> Result<Self, TopologyError> {
        let mut l = [R::zero(); D];
        let mut full = R::one();
        for a in 0..D {
            l[a] = hi[a] - lo[a];
            full *= l[a];
        }
        let eps = full * R::from_f64(1e-12).expect("1e-12 representable");

        match primitive {
            Primitive::Halfspace { normal, offset } => {
                Ok(Self::from_halfspace(&l, normal, *offset, lo, full, eps))
            }
            Primitive::Cylinder {
                axis,
                center,
                radius,
            } => {
                if D != 3 || *axis >= D {
                    return Err(TopologyError::InvalidInput(format!(
                        "Cylinder cut requires D = 3 and axis < D (got D = {D}, axis = {axis})"
                    )));
                }
                Ok(Self::from_cylinder(
                    &l, *axis, center, *radius, lo, full, eps,
                ))
            }
            Primitive::Ball { center, radius } => {
                if D != 2 {
                    return Err(TopologyError::InvalidInput(format!(
                        "Ball cut is supported for D = 2 only in Group A (got D = {D}); the 3D ball closed form is deferred"
                    )));
                }
                Ok(Self::from_disk(&l, center, *radius, lo, full, eps))
            }
        }
    }

    fn from_halfspace(l: &[R; D], normal: &[R; D], offset: R, lo: [R; D], full: R, eps: R) -> Self {
        // Local-coordinate offset: solid is { n·x ≤ offset } ⇒ { n·(lo + u) ≤ offset }.
        let mut n_dot_lo = R::zero();
        for a in 0..D {
            n_dot_lo += normal[a] * lo[a];
        }
        let c_local = offset - n_dot_lo;

        let solid = box_halfspace_solid_volume(l.as_slice(), normal.as_slice(), c_local);
        let fluid = full - solid;
        if solid <= eps {
            return Self::fluid(full);
        }
        if fluid <= eps {
            return Self::solid(full);
        }

        // Per-face apertures: fluid fraction of each (D−1)-face.
        let mut apertures = [[R::zero(); 2]; D];
        for a in 0..D {
            let mut l_sub: Vec<R> = Vec::with_capacity(D - 1);
            let mut n_sub: Vec<R> = Vec::with_capacity(D - 1);
            let mut face_area = R::one();
            for b in 0..D {
                if b != a {
                    l_sub.push(l[b]);
                    n_sub.push(normal[b]);
                    face_area *= l[b];
                }
            }
            for (side, &face_coord) in [R::zero(), l[a]].iter().enumerate() {
                let c_sub = c_local - normal[a] * face_coord;
                let solid_face = box_halfspace_solid_volume(&l_sub, &n_sub, c_sub);
                apertures[a][side] = clamp01((face_area - solid_face) / face_area);
            }
        }

        // Cut-face fragment: the planar cross-section. Outward normal = +normal (points to the
        // n·x ≥ offset fluid side).
        let area = box_halfspace_cross_area(l.as_slice(), normal.as_slice(), c_local);
        let mut fragments = Vec::new();
        if area > eps {
            // Centroid: the cell centre projected onto the cut plane `n·x = offset`, so it lies on
            // the wetted surface (the anchor for the wall-normal friction diagnostic).
            let mut nn = R::zero();
            let mut n_dot_xc = R::zero();
            let mut centroid = [R::zero(); D];
            for a in 0..D {
                let xc = lo[a] + l[a] / (R::one() + R::one());
                centroid[a] = xc;
                nn += normal[a] * normal[a];
                n_dot_xc += normal[a] * xc;
            }
            if nn > R::zero() {
                let t = (n_dot_xc - offset) / nn;
                for a in 0..D {
                    centroid[a] -= t * normal[a];
                }
            }
            fragments.push(CutFaceFragment::new(
                area,
                *normal,
                centroid,
                super::source_geometry::SourceGeometry::Plane,
            ));
        }
        Self::cut(full, fluid, apertures, fragments)
    }

    fn from_cylinder(
        l: &[R; D],
        axis: usize,
        center: &[R; D],
        radius: R,
        lo: [R; D],
        full: R,
        eps: R,
    ) -> Self {
        // The two perpendicular axes form the disk cross-section.
        let perp: Vec<usize> = (0..D).filter(|&a| a != axis).collect();
        let (p, q) = (perp[0], perp[1]);
        let lo2 = [lo[p], lo[q]];
        let hi2 = [lo[p] + l[p], lo[q] + l[q]];
        let c2 = [center[p], center[q]];

        let solid_cross = rect_disk_solid_area(lo2, hi2, c2, radius);
        let solid = solid_cross * l[axis];
        let fluid = full - solid;
        if solid <= eps {
            return Self::fluid(full);
        }
        if fluid <= eps {
            return Self::solid(full);
        }

        let mut apertures = [[R::zero(); 2]; D];
        let rect_area = l[p] * l[q];
        // Faces perpendicular to the cylinder axis: the full disk cross-section, identical on
        // both sides (the cylinder is uniform along its axis).
        let ax_fluid_frac = clamp01((rect_area - solid_cross) / rect_area);
        apertures[axis][0] = ax_fluid_frac;
        apertures[axis][1] = ax_fluid_frac;
        // Faces perpendicular to a cross-section axis: a chord of the disk extruded along the
        // cylinder axis.
        for (&face_axis, &other_axis) in [(p, q), (q, p)].iter().map(|(a, b)| (a, b)) {
            let face_area = l[other_axis] * l[axis];
            for (side, &face_coord) in [lo[face_axis], lo[face_axis] + l[face_axis]]
                .iter()
                .enumerate()
            {
                let chord = disk_chord_overlap(
                    face_coord,
                    center[face_axis],
                    lo[other_axis],
                    lo[other_axis] + l[other_axis],
                    center[other_axis],
                    radius,
                );
                let solid_face = chord * l[axis];
                apertures[face_axis][side] = clamp01((face_area - solid_face) / face_area);
            }
        }

        // Fragment: the curved cylinder surface inside the cell.
        let arc = circle_in_rect_arc_len(lo2, hi2, c2, radius);
        let mut fragments = Vec::new();
        let area = arc * l[axis];
        if area > eps {
            let mut normal = [R::zero(); D];
            // Representative radial outward normal at the cell-centre projection.
            let cell_cx = lo[p] + l[p] / (R::one() + R::one());
            let cell_cy = lo[q] + l[q] / (R::one() + R::one());
            let rx = cell_cx - center[p];
            let ry = cell_cy - center[q];
            let rn = (rx * rx + ry * ry).sqrt();
            // Centroid: the cell-centre projection pushed out to the cylinder surface (radius from
            // the axis), at the cell centre along the cylinder axis.
            let mut centroid = [R::zero(); D];
            centroid[axis] = lo[axis] + l[axis] / (R::one() + R::one());
            if rn > R::zero() {
                normal[p] = rx / rn;
                normal[q] = ry / rn;
                centroid[p] = center[p] + radius * rx / rn;
                centroid[q] = center[q] + radius * ry / rn;
            } else {
                centroid[p] = center[p];
                centroid[q] = center[q];
            }
            fragments.push(CutFaceFragment::new(
                area,
                normal,
                centroid,
                super::source_geometry::SourceGeometry::Cylinder,
            ));
        }
        Self::cut(full, fluid, apertures, fragments)
    }

    fn from_disk(l: &[R; D], center: &[R; D], radius: R, lo: [R; D], full: R, eps: R) -> Self {
        // D == 2 guaranteed by the caller.
        let lo2 = [lo[0], lo[1]];
        let hi2 = [lo[0] + l[0], lo[1] + l[1]];
        let c2 = [center[0], center[1]];

        let solid = rect_disk_solid_area(lo2, hi2, c2, radius);
        let fluid = full - solid;
        if solid <= eps {
            return Self::fluid(full);
        }
        if fluid <= eps {
            return Self::solid(full);
        }

        let mut apertures = [[R::zero(); 2]; D];
        for (&face_axis, &other_axis) in [(0usize, 1usize), (1, 0)].iter().map(|(a, b)| (a, b)) {
            let face_len = l[other_axis];
            for (side, &face_coord) in [lo[face_axis], lo[face_axis] + l[face_axis]]
                .iter()
                .enumerate()
            {
                let chord = disk_chord_overlap(
                    face_coord,
                    center[face_axis],
                    lo[other_axis],
                    lo[other_axis] + l[other_axis],
                    center[other_axis],
                    radius,
                );
                apertures[face_axis][side] = clamp01((face_len - chord) / face_len);
            }
        }

        let arc = circle_in_rect_arc_len(lo2, hi2, c2, radius);
        let mut fragments = Vec::new();
        if arc > eps {
            let mut normal = [R::zero(); D];
            let cell_cx = lo[0] + l[0] / (R::one() + R::one());
            let cell_cy = lo[1] + l[1] / (R::one() + R::one());
            let rx = cell_cx - center[0];
            let ry = cell_cy - center[1];
            let rn = (rx * rx + ry * ry).sqrt();
            // Centroid: the cell-centre projection pushed out to the disk circumference.
            let mut centroid = [R::zero(); D];
            centroid[0] = center[0];
            centroid[1] = center[1];
            if rn > R::zero() {
                normal[0] = rx / rn;
                normal[1] = ry / rn;
                centroid[0] = center[0] + radius * rx / rn;
                centroid[1] = center[1] + radius * ry / rn;
            }
            fragments.push(CutFaceFragment::new(
                arc,
                normal,
                centroid,
                super::source_geometry::SourceGeometry::Sphere,
            ));
        }
        Self::cut(full, fluid, apertures, fragments)
    }
}

/// Clamp a fraction to `[0, 1]`.
fn clamp01<R: RealField>(x: R) -> R {
    if x < R::zero() {
        R::zero()
    } else if x > R::one() {
        R::one()
    } else {
        x
    }
}

impl<const D: usize, R: RealField + FromPrimitive> CutCellRegistry<D, R> {
    /// Build a registry by intersecting every top `D`-cell of `complex` with `primitive`,
    /// using the physical node coordinates implied by `geom` (the separable / tensor-product
    /// grid the unit, uniform, per-axis and graded `PerEdge` tiers all produce — design D7).
    /// Only cut and solid cells are recorded; fluid cells stay on the fast path.
    pub fn from_primitive<S: SignatureMarker>(
        complex: &LatticeComplex<D, R>,
        geom: &CubicalReggeGeometry<D, R, S>,
        primitive: &Primitive<D, R>,
    ) -> Result<Self, TopologyError> {
        let nodes = separable_node_coords(complex, geom);
        let mut registry = Self::new();

        for cell in complex.iter_cells(D) {
            let base = *cell.position();
            let mut lo = [R::zero(); D];
            let mut hi = [R::zero(); D];
            for a in 0..D {
                lo[a] = nodes[a][base[a]];
                hi[a] = nodes[a][base[a] + 1];
            }
            let cut = CutCell::from_box(primitive, lo, hi)?;
            if !cut.class().is_fluid()
                && let Some(idx) = complex.cell_index(&cell)
            {
                registry.insert(idx, cut);
            }
        }
        Ok(registry)
    }
}

/// Physical vertex coordinates per axis for a separable (tensor-product) grid: `nodes[a][i]`
/// is the coordinate of the `i`-th grid line along axis `a`. Built from the geometry's
/// per-axis lengths (unit / uniform / per-axis) or its per-edge graded lengths.
fn separable_node_coords<const D: usize, R: RealField, S: SignatureMarker>(
    complex: &LatticeComplex<D, R>,
    geom: &CubicalReggeGeometry<D, R, S>,
) -> Vec<Vec<R>> {
    let shape = *complex.shape();
    let mut nodes: Vec<Vec<R>> = Vec::with_capacity(D);
    for a in 0..D {
        let mut col: Vec<R> = Vec::with_capacity(shape[a] + 1);
        col.push(R::zero());
        if let Some(axis_lengths) = geom.axis_lengths() {
            // Uniform per-axis spacing.
            let la = axis_lengths[a];
            let mut acc = R::zero();
            for _ in 0..shape[a] {
                acc += la;
                col.push(acc);
            }
        } else {
            // Per-edge graded lengths: sample the edge length at each position along axis `a`
            // (separable, so the perpendicular coordinates do not matter).
            for i in 0..shape[a] {
                let mut probe = [0usize; D];
                probe[a] = i;
                let edge_id = complex.edge_index(probe, a);
                let len = geom.edge_length_at(edge_id).unwrap_or_else(R::one);
                let prev = col[i];
                col.push(prev + len);
            }
        }
        nodes.push(col);
    }
    nodes
}
