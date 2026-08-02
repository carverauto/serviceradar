/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::collections::HashSet;
use std::f64::consts::PI;

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

use crate::TopologyError;
use crate::types::regge_geometry::ReggeGeometry;
use crate::{Simplex, SimplicialComplex};

impl<R> ReggeGeometry<R>
where
    R: RealField + FromPrimitive,
{
    /// Calculates the Ricci Curvature (Deficit Angles) for all bones in the complex.
    ///
    /// The resulting tensor contains the deficit angle `δ` for each `(n-2)`-simplex.
    pub fn calculate_ricci_curvature(
        &self,
        complex: &SimplicialComplex<R>,
    ) -> Result<CausalTensor<R>, TopologyError> {
        let dim = complex.max_simplex_dimension();
        if dim < 2 {
            return Err(TopologyError::DimensionMismatch(
                "Curvature is undefined for dimension < 2".to_string(),
            ));
        }

        let bone_grade = dim - 2;
        let num_bones = complex.skeletons[bone_grade].simplices.len();

        let mut deficits = vec![R::zero(); num_bones];

        if complex.boundary_operators.len() < dim {
            return Err(TopologyError::InvalidInput(
                "SimplicialComplex requires boundary operators for curvature calculation"
                    .to_string(),
            ));
        }

        let co_bone_matrix = &complex.boundary_operators[bone_grade];
        let co_face_matrix = &complex.boundary_operators[dim - 1];

        let co_bone_rows = co_bone_matrix.row_indices();
        let co_bone_cols = co_bone_matrix.col_indices();
        let co_face_rows = co_face_matrix.row_indices();
        let co_face_cols = co_face_matrix.col_indices();

        let two_pi = <R as FromPrimitive>::from_f64(2.0 * PI)
            .expect("2π is representable in every RealField");

        for bone_idx in 0..num_bones {
            let mut is_boundary_bone = false;

            let start = co_bone_rows[bone_idx];
            let end = co_bone_rows[bone_idx + 1];
            let incident_faces = &co_bone_cols[start..end];

            let mut relevant_simplices = HashSet::new();

            for &face_idx in incident_faces {
                let f_start = co_face_rows[face_idx];
                let f_end = co_face_rows[face_idx + 1];
                let count = f_end - f_start;

                if count == 1 {
                    is_boundary_bone = true;
                    break;
                }

                let incident_simplices = &co_face_cols[f_start..f_end];
                for &simplex_idx in incident_simplices {
                    relevant_simplices.insert(simplex_idx);
                }
            }

            if is_boundary_bone {
                deficits[bone_idx] = R::zero();
                continue;
            }

            let mut total_angle = R::zero();
            let bone_simplex = &complex.skeletons[bone_grade].simplices[bone_idx];

            for &simplex_idx in &relevant_simplices {
                let simplex = &complex.skeletons[dim].simplices[simplex_idx];
                let angle = self.compute_dihedral_angle(complex, simplex, bone_simplex)?;
                total_angle += angle;
            }

            deficits[bone_idx] = two_pi - total_angle;
        }

        CausalTensor::new(deficits, vec![num_bones]).map_err(TopologyError::from)
    }

    /// Computes the dihedral angle of an n-simplex at a specific (n-2)-face (bone).
    fn compute_dihedral_angle(
        &self,
        complex: &SimplicialComplex<R>,
        simplex_n: &Simplex,
        bone: &Simplex,
    ) -> Result<R, TopologyError> {
        let n_dim = simplex_n.vertices.len() - 1;
        let two = <R as FromPrimitive>::from_f64(2.0).expect("2.0 representable");
        let one = R::one();
        let neg_one = -one;

        if n_dim == 2 {
            // 2D: angle at a vertex in a triangle; Law of Cosines.
            let p = bone.vertices[0];
            let other_verts: Vec<_> = simplex_n
                .vertices
                .iter()
                .filter(|&&v| v != p)
                .cloned()
                .collect();
            if other_verts.len() != 2 {
                return Err(TopologyError::InvalidInput(
                    "Simplex topology error".to_string(),
                ));
            }
            let q = other_verts[0];
            let r = other_verts[1];

            let l_pq = self.get_edge_length(complex, p, q)?;
            let l_pr = self.get_edge_length(complex, p, r)?;
            let l_qr = self.get_edge_length(complex, q, r)?;

            if l_pq + l_pr <= l_qr || l_pq + l_qr <= l_pr || l_pr + l_qr <= l_pq {
                return Err(TopologyError::ManifoldError(format!(
                    "Triangle inequality violated in simplex {:?}",
                    simplex_n.vertices
                )));
            }

            let cos_theta = (l_pq * l_pq + l_pr * l_pr - l_qr * l_qr) / (two * l_pq * l_pr);
            let cos_theta = clamp(cos_theta, neg_one, one);
            return Ok(cos_theta.acos());
        }

        if n_dim == 3 {
            // 3D: angle at an edge in a tetrahedron, using sin(θ) = 3 V l / (2 A1 A2).
            let b_u = bone.vertices[0];
            let b_v = bone.vertices[1];

            let others: Vec<_> = simplex_n
                .vertices
                .iter()
                .filter(|&&v| v != b_u && v != b_v)
                .cloned()
                .collect();
            if others.len() != 2 {
                return Err(TopologyError::InvalidInput(
                    "Bone not in simplex".to_string(),
                ));
            }
            let o1 = others[0];
            let o2 = others[1];

            let area1 = self.simplex_area(complex, b_u, b_v, o1)?;
            let area2 = self.simplex_area(complex, b_u, b_v, o2)?;
            let vol = self.simplex_volume(complex, simplex_n)?;
            let len_bone = self.get_edge_length(complex, b_u, b_v)?;

            let tiny = <R as FromPrimitive>::from_f64(1e-9).expect("1e-9 representable");
            if area1 < tiny || area2 < tiny {
                return Err(TopologyError::ManifoldError(
                    "Degenerate face in tetrahedron".to_string(),
                ));
            }

            let three = <R as FromPrimitive>::from_f64(3.0).expect("3.0 representable");
            let sin_theta: R = (three * vol * len_bone) / (two * area1 * area2);
            let sin_theta = clamp(sin_theta, neg_one, one);
            return Ok(sin_theta.asin());
        }

        // 4D not implemented
        Ok(R::zero())
    }

    fn get_edge_length(
        &self,
        complex: &SimplicialComplex<R>,
        u: usize,
        v: usize,
    ) -> Result<R, TopologyError> {
        let edge = Simplex {
            vertices: if u < v { vec![u, v] } else { vec![v, u] },
        };
        if let Some(idx) = complex.skeletons[1].get_index(&edge) {
            Ok(self.edge_lengths.as_slice()[idx])
        } else {
            Err(TopologyError::SimplexNotFound())
        }
    }

    fn simplex_area(
        &self,
        complex: &SimplicialComplex<R>,
        a: usize,
        b: usize,
        c: usize,
    ) -> Result<R, TopologyError> {
        let lab = self.get_edge_length(complex, a, b)?;
        let lbc = self.get_edge_length(complex, b, c)?;
        let lca = self.get_edge_length(complex, c, a)?;

        let two = <R as FromPrimitive>::from_f64(2.0).expect("2.0 representable");
        let s = (lab + lbc + lca) / two;
        let area_sq = s * (s - lab) * (s - lbc) * (s - lca);
        if area_sq < R::zero() {
            return Err(TopologyError::ManifoldError(
                "Triangle inequality failed for face".to_string(),
            ));
        }
        Ok(area_sq.sqrt())
    }

    fn simplex_volume(
        &self,
        complex: &SimplicialComplex<R>,
        s: &Simplex,
    ) -> Result<R, TopologyError> {
        let u = s.vertices[0];
        let v = s.vertices[1];
        let w = s.vertices[2];
        let x = s.vertices[3];

        let l_uv = self.get_edge_length(complex, u, v)?;
        let l_uw = self.get_edge_length(complex, u, w)?;
        let l_ux = self.get_edge_length(complex, u, x)?;
        let l_vw = self.get_edge_length(complex, v, w)?;
        let l_vx = self.get_edge_length(complex, v, x)?;
        let l_wx = self.get_edge_length(complex, w, x)?;

        let d_uv = l_uv * l_uv;
        let d_uw = l_uw * l_uw;
        let d_ux = l_ux * l_ux;
        let d_vw = l_vw * l_vw;
        let d_vx = l_vx * l_vx;
        let d_wx = l_wx * l_wx;

        let zero = R::zero();
        let one = R::one();

        let mat = vec![
            vec![zero, one, one, one, one],
            vec![one, zero, d_uv, d_uw, d_ux],
            vec![one, d_uv, zero, d_vw, d_vx],
            vec![one, d_uw, d_vw, zero, d_wx],
            vec![one, d_ux, d_vx, d_wx, zero],
        ];

        let det = Self::det_recursive(&mat);
        let denom = <R as FromPrimitive>::from_f64(288.0).expect("288 representable");
        let vol_sq = det / denom;

        if vol_sq < R::zero() {
            return Err(TopologyError::ManifoldError(
                "Tetrahedron inequality violated (Vol^2 < 0)".to_string(),
            ));
        }

        Ok(vol_sq.sqrt())
    }

    fn det_recursive(m: &[Vec<R>]) -> R {
        let n = m.len();
        if n == 1 {
            return m[0][0];
        }
        if n == 2 {
            return m[0][0] * m[1][1] - m[0][1] * m[1][0];
        }

        let mut det = R::zero();
        let one = R::one();
        let neg_one = -one;
        for (c, &val) in m[0].iter().enumerate().take(n) {
            let sign = if c % 2 == 0 { one } else { neg_one };
            let sub = Self::submatrix(m, 0, c);
            det += sign * val * Self::det_recursive(&sub);
        }
        det
    }

    fn submatrix(m: &[Vec<R>], skip_r: usize, skip_c: usize) -> Vec<Vec<R>> {
        let n = m.len();
        let mut res = Vec::with_capacity(n - 1);
        for (r, row) in m.iter().enumerate().take(n) {
            if r == skip_r {
                continue;
            }
            let mut new_row = Vec::with_capacity(n - 1);
            for (c, &val) in row.iter().enumerate().take(n) {
                if c == skip_c {
                    continue;
                }
                new_row.push(val);
            }
            res.push(new_row);
        }
        res
    }
}

/// Generic clamp on `RealField` (avoids `f64`-specific `clamp`).
fn clamp<R: RealField>(x: R, lo: R, hi: R) -> R {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}
