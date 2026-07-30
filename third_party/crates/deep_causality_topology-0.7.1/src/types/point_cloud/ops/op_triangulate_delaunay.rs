/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! 2D Delaunay triangulation via the Bowyer-Watson algorithm.
//!
//! Sibling to [`super::op_triangulate`] (Vietoris-Rips). Both methods coexist;
//! callers pick by use case:
//!
//! - **`PointCloud::triangulate(radius)`** — Vietoris-Rips clique complex.
//!   Right for TDA (persistent homology, Euler characteristic). Produces
//!   non-manifold complexes on dense planar inputs (e.g. all four corners of
//!   a unit square at radius √2 yield four overlapping triangles).
//!
//! - **`PointCloud::triangulate_delaunay()`** — 2D Delaunay triangulation
//!   (this module). Right for DEC (Hodge ⋆, codifferential, Laplacian,
//!   `Manifold::hodge_decompose`). The returned `SimplicialComplex<T>`
//!   satisfies the manifold-property check for any non-degenerate planar
//!   input.
//!
//! The Hodge ⋆ operators on the returned complex are populated lazily on
//! first access via [`crate::SimplicialComplex::hodge_star_operators`], the
//! same path used by Vietoris-Rips post-`harden-simplicial-hodge-degeneracy-
//! detection`.

use super::op_triangulate::find_duplicate_points;
use crate::{PointCloud, Simplex, SimplicialComplex, Skeleton, TopologyError};
use deep_causality_num::{Float, Zero};
use deep_causality_sparse::CsrMatrix;
use std::collections::{BTreeSet, HashSet};
use std::iter::Sum;

#[derive(Debug, PartialEq, Eq)]
enum InCircle {
    Inside,
    Outside,
    #[allow(dead_code)]
    OnCircle,
}

/// In-circumcircle predicate for a counter-clockwise oriented triangle.
///
/// Returns `Inside` when the test point `d` lies strictly inside the
/// circumcircle of the triangle `(a, b, c)`, `Outside` when it lies strictly
/// outside, and `OnCircle` when it falls within `T::epsilon() * 100` of the
/// circle's boundary. The cocircular case is treated as `Outside` for the
/// Bowyer-Watson "bad triangle" detection, producing a deterministic
/// triangulation dependent on input-point insertion order (per
/// `design.md` Decision 3).
///
/// Assumes `(a, b, c)` is counter-clockwise. The Bowyer-Watson loop in this
/// module maintains that invariant: the super-triangle is constructed CCW,
/// and cavity re-triangulation fans new triangles in CCW order.
fn in_circumcircle<T>(a: [T; 2], b: [T; 2], c: [T; 2], d: [T; 2]) -> InCircle
where
    T: Float + From<f64> + Copy,
{
    let ax = a[0] - d[0];
    let ay = a[1] - d[1];
    let bx = b[0] - d[0];
    let by = b[1] - d[1];
    let cx = c[0] - d[0];
    let cy = c[1] - d[1];
    let a_sq = ax * ax + ay * ay;
    let b_sq = bx * bx + by * by;
    let c_sq = cx * cx + cy * cy;
    // 3x3 determinant expansion along the first row.
    let det =
        ax * (by * c_sq - cy * b_sq) - ay * (bx * c_sq - cx * b_sq) + a_sq * (bx * cy - cx * by);
    let tol = T::epsilon() * <T as From<f64>>::from(100.0);
    if det > tol {
        InCircle::Inside
    } else if det < -tol {
        InCircle::Outside
    } else {
        InCircle::OnCircle
    }
}

/// Returns `true` when every input point lies on a single line within
/// tolerance. Uses the signed area of the triangle formed by the first two
/// points and each subsequent point; if all such areas vanish within
/// `T::epsilon() * 100`, the input is collinear.
///
/// Assumes `n >= 3` and that the first two points are distinct (the
/// duplicate-point check at the top of `triangulate_delaunay` enforces this).
fn all_collinear<T>(coords: &[T], n: usize) -> bool
where
    T: Float + From<f64> + Copy,
{
    if n < 3 {
        return false;
    }
    let tol = T::epsilon() * <T as From<f64>>::from(100.0);
    let v1x = coords[2] - coords[0];
    let v1y = coords[3] - coords[1];
    for k in 2..n {
        let vkx = coords[k * 2] - coords[0];
        let vky = coords[k * 2 + 1] - coords[1];
        let cross = v1x * vky - v1y * vkx;
        if cross.abs() > tol {
            return false;
        }
    }
    true
}

impl<T, D> PointCloud<T, D>
where
    T: Float + Sum + From<f64> + Zero + PartialOrd + Copy,
{
    /// Builds a 2D Delaunay triangulation of the point cloud via the Bowyer-
    /// Watson algorithm. The returned `SimplicialComplex<T>` is manifold-
    /// respecting: oriented, satisfying the link condition, with no
    /// overlapping interior simplices. It is drop-in compatible with
    /// [`crate::Manifold::with_metric`] and every downstream DEC operator
    /// (`hodge_star`, `codifferential`, `laplacian`, `hodge_decompose`).
    ///
    /// The Hodge ⋆ operators are populated lazily on first access via
    /// [`crate::SimplicialComplex::hodge_star_operators`], the same path
    /// Vietoris-Rips uses post-`harden-simplicial-hodge-degeneracy-detection`.
    ///
    /// # Preconditions
    ///
    /// 1. Ambient dimension must be 2 (`self.points.shape()[1] == 2`).
    /// 2. At least 3 input points.
    /// 3. No duplicate input points (within `T::epsilon() * max_extent`).
    /// 4. Input points must not all be collinear (within
    ///    `T::epsilon() * 100`).
    ///
    /// Cocircular inputs (e.g. the four corners of the unit square on the
    /// unit circle) are accepted with a deterministic tiebreak: the
    /// cocircular sub-quadrilateral receives whichever diagonal the
    /// Bowyer-Watson insertion order produces first.
    ///
    /// # Errors
    ///
    /// Returns `Err(TopologyError::PointCloudError(_))` for any precondition
    /// violation. Discriminating messages cover each rejection class.
    ///
    /// # Robustness
    ///
    /// The first version uses naive `f64`/generic-`Float` predicates with a
    /// documented tolerance of `T::epsilon() * 100`. Inputs at coordinates
    /// `O(1)` in magnitude are sound; inputs at extreme scales may exhibit
    /// floating-point edge behaviour. The adaptive-precision predicate
    /// (Shewchuk's exact arithmetic) is a deferred follow-up.
    pub fn triangulate_delaunay(&self) -> Result<SimplicialComplex<T>, TopologyError> {
        // 1. Degeneracy guards
        let n = self.len();
        if n == 0 {
            return Err(TopologyError::PointCloudError(
                "triangulate_delaunay: empty point cloud".to_string(),
            ));
        }
        let dim = self.points.shape()[1];
        if dim != 2 {
            return Err(TopologyError::PointCloudError(format!(
                "triangulate_delaunay requires 2D ambient (D == 2), got D == {}",
                dim
            )));
        }
        if n < 3 {
            return Err(TopologyError::PointCloudError(format!(
                "triangulate_delaunay requires at least 3 points, got {}",
                n
            )));
        }
        let coords = self.points.as_slice();
        if let Some((i, j)) = find_duplicate_points(coords, n, 2) {
            return Err(TopologyError::PointCloudError(format!(
                "triangulate_delaunay: duplicate point at index {} matches index {}",
                i, j
            )));
        }
        if all_collinear(coords, n) {
            return Err(TopologyError::PointCloudError(
                "triangulate_delaunay requires non-collinear input".to_string(),
            ));
        }

        // 2. Construct super-triangle covering the input bounding box with
        //    100x expansion in each direction (per design.md Decision 2).
        let mut min_x = coords[0];
        let mut max_x = coords[0];
        let mut min_y = coords[1];
        let mut max_y = coords[1];
        for i in 1..n {
            let x = coords[i * 2];
            let y = coords[i * 2 + 1];
            if x < min_x {
                min_x = x;
            }
            if x > max_x {
                max_x = x;
            }
            if y < min_y {
                min_y = y;
            }
            if y > max_y {
                max_y = y;
            }
        }
        let dx = max_x - min_x;
        let dy = max_y - min_y;
        let hundred = <T as From<f64>>::from(100.0);
        let two_hundred = <T as From<f64>>::from(200.0);
        let st0 = [min_x - hundred * dx, min_y - hundred * dy];
        let st1 = [max_x + two_hundred * dx, min_y - hundred * dy];
        let st2 = [min_x - hundred * dx, max_y + two_hundred * dy];

        let st0_idx = n;
        let st1_idx = n + 1;
        let st2_idx = n + 2;

        // Combined coordinate buffer (input + super-triangle vertices)
        let mut all_coords: Vec<T> = Vec::with_capacity((n + 3) * 2);
        all_coords.extend_from_slice(coords);
        all_coords.push(st0[0]);
        all_coords.push(st0[1]);
        all_coords.push(st1[0]);
        all_coords.push(st1[1]);
        all_coords.push(st2[0]);
        all_coords.push(st2[1]);

        // Working triangle list. Each triangle is [i0, i1, i2] in CCW order.
        let mut triangles: Vec<[usize; 3]> = vec![[st0_idx, st1_idx, st2_idx]];

        // 3. Bowyer-Watson insertion loop
        for i in 0..n {
            let p = [coords[i * 2], coords[i * 2 + 1]];

            // 3a. Identify "bad" triangles (those whose circumcircle
            //     strictly contains p).
            let mut bad: Vec<usize> = Vec::new();
            for (t_idx, t) in triangles.iter().enumerate() {
                let a = [all_coords[t[0] * 2], all_coords[t[0] * 2 + 1]];
                let b = [all_coords[t[1] * 2], all_coords[t[1] * 2 + 1]];
                let c = [all_coords[t[2] * 2], all_coords[t[2] * 2 + 1]];
                if in_circumcircle(a, b, c, p) == InCircle::Inside {
                    bad.push(t_idx);
                }
            }

            // 3b. Extract cavity boundary as directed edges. An edge (u, v)
            //     belongs to the boundary iff it appears in some bad
            //     triangle's CCW boundary AND its reverse (v, u) does not
            //     appear in any bad triangle. Interior edges of the cavity
            //     are shared by two bad triangles in opposite directions
            //     and cancel.
            let mut directed_edges: HashSet<(usize, usize)> = HashSet::new();
            for &t_idx in &bad {
                let t = triangles[t_idx];
                directed_edges.insert((t[0], t[1]));
                directed_edges.insert((t[1], t[2]));
                directed_edges.insert((t[2], t[0]));
            }
            let boundary: Vec<(usize, usize)> = directed_edges
                .iter()
                .filter(|&&(u, v)| !directed_edges.contains(&(v, u)))
                .copied()
                .collect();

            // 3c. Remove bad triangles from the working list.
            let mut bad_sorted = bad;
            bad_sorted.sort_unstable();
            for &idx in bad_sorted.iter().rev() {
                triangles.swap_remove(idx);
            }

            // 3d. Re-triangulate the cavity by fanning new triangles from p
            //     (vertex index i). Each boundary edge (u, v) becomes the
            //     CCW triangle (u, v, i) — orientation preserved because p
            //     lies on the LEFT of (u → v) by construction (inside the
            //     cavity).
            for (u, v) in boundary {
                triangles.push([u, v, i]);
            }
        }

        // 4. Drop triangles that still reference super-triangle vertices.
        triangles.retain(|t| t[0] < n && t[1] < n && t[2] < n);

        debug_assert!(
            triangles.iter().all(|t| t[0] < n && t[1] < n && t[2] < n),
            "post-removal invariant: every surviving triangle's vertices are real input points"
        );

        // 5. Build the 0-, 1-, and 2-skeletons.
        let zero_simplices: Vec<Simplex> = (0..n).map(|i| Simplex::new(vec![i])).collect();
        let zero_skeleton = Skeleton::new(0, zero_simplices);

        let mut edge_set: BTreeSet<(usize, usize)> = BTreeSet::new();
        for t in &triangles {
            for (u, v) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])] {
                let key = if u < v { (u, v) } else { (v, u) };
                edge_set.insert(key);
            }
        }
        let one_simplices: Vec<Simplex> = edge_set
            .iter()
            .map(|&(a, b)| Simplex::new(vec![a, b]))
            .collect();
        let one_skeleton = Skeleton::new(1, one_simplices);

        let mut two_simplices: Vec<Simplex> = triangles
            .iter()
            .map(|t| {
                let mut v = vec![t[0], t[1], t[2]];
                v.sort_unstable();
                Simplex::new(v)
            })
            .collect();
        two_simplices.sort();
        two_simplices.dedup();
        let two_skeleton = Skeleton::new(2, two_simplices);

        let skeletons = vec![zero_skeleton, one_skeleton, two_skeleton];

        // 6. Build boundary operators (same convention as
        //    `op_triangulate.rs`).
        let max_dim = skeletons.len() - 1;
        let mut boundary_ops = Vec::new();
        for k in 0..max_dim {
            let rows = skeletons[k].simplices.len();
            let cols = skeletons[k + 1].simplices.len();
            let mut triplets = Vec::new();
            for (col, simplex) in skeletons[k + 1].simplices.iter().enumerate() {
                for i in 0..=(k + 1) {
                    let mut face_verts = simplex.vertices.clone();
                    face_verts.remove(i);
                    let face = Simplex::new(face_verts);
                    if let Some(row) = skeletons[k].get_index(&face) {
                        let sign = if i % 2 == 0 { 1 } else { -1 };
                        triplets.push((row, col, sign));
                    }
                }
            }
            boundary_ops.push(CsrMatrix::from_triplets(rows, cols, &triplets).unwrap());
        }

        // 7. Coboundary operators (transpose of boundary).
        let coboundary_ops: Vec<_> = boundary_ops.iter().map(|b| b.transpose()).collect();

        // 8. Construct via `with_geometry`. The Hodge ⋆ operators populate
        //    lazily on first access via
        //    `SimplicialComplex::hodge_star_operators()`.
        Ok(SimplicialComplex::with_geometry(
            skeletons,
            boundary_ops,
            coboundary_ops,
            coords.to_vec(),
            2,
        ))
    }
}
