/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Simplex, Skeleton, Topology, TopologyError};
use core::fmt::Debug;
use core::ops::Mul;
use deep_causality_algebra::Field;
use deep_causality_num::Zero;
use deep_causality_tensor::CausalTensor;
use std::sync::Arc;

impl<T> Topology<T>
where
    T: Field + Copy + Clone + Zero + Mul<Output = T> + Debug,
{
    /// Computes the Cup Product `α ⌣ β` of a p-cochain and a q-cochain.
    ///
    /// The result is a (p+q)-cochain.
    ///
    /// # Mathematical Definition (Alexander-Whitney)
    /// For a (p+q)-simplex `σ = [v_0, ..., v_{p+q}]`, the cup product is:
    ///
    /// (α ⌣ β)(σ) = α([v_0, ..., v_p]) * β([v_p, ..., v_{p+q}])
    ///
    /// * `α` evaluates on the **Front Face** (first p+1 vertices).
    /// * `β` evaluates on the **Back Face** (last q+1 vertices).
    ///
    /// # Arguments
    /// * `other`: The q-cochain `β`. `self` is the p-cochain `α`.
    ///
    /// # Returns
    /// A new `CausalTopology` of grade `p+q`.
    pub fn cup_product(&self, other: &Topology<T>) -> Result<Topology<T>, TopologyError> {
        // 1. Determine Grades
        let p = self.grade;
        let q = other.grade;
        let r = p + q;

        // 2. Validation
        // Ensure both fields live on the same Complex
        if !Arc::ptr_eq(&self.complex, &other.complex) {
            return Err(TopologyError::GenericError("Complex Mismatch".to_string()));
        }

        // If grade exceeds manifold dimension, the result is zero.
        if r > self.complex.max_simplex_dimension() {
            // Return a zero field of grade r (if valid grade) or empty
            // Here we assume r is valid or return empty.
            let zero_len = if r < self.complex.skeletons().len() {
                self.complex.skeletons()[r].simplices().len()
            } else {
                0
            };

            return Ok(Topology {
                complex: self.complex.clone(),
                grade: r,
                data: CausalTensor::new(vec![T::zero(); zero_len], vec![zero_len]).unwrap(),
                cursor: 0,
            });
        }

        // 3. Get Skeletons
        let p_skeleton = &self.complex.skeletons()[p];
        let q_skeleton = &self.complex.skeletons()[q];
        let target_skeleton: &Skeleton = &self.complex.skeletons()[r];

        let target_count = target_skeleton.simplices().len();
        let mut result_values = Vec::with_capacity(target_count);

        // 4. Iterate over every simplex in the target dimension (p+q)
        for simplex in target_skeleton.simplices() {
            // The vertices are assumed to be sorted by the Skeleton construction.
            // vertices: [v0, v1, ..., vp, ..., v(p+q)]
            let verts: &[usize] = simplex.vertices();

            // Extract Faces based on Alexander-Whitney diagonal
            // Front Face (alpha): 0..=p
            let front_verts = verts[0..=p].to_vec();
            let front_simplex = Simplex::new(front_verts);

            // Back Face (beta): p..=r
            let back_verts = verts[p..=r].to_vec();
            let back_simplex = Simplex::new(back_verts);

            // 5. Lookup Indices
            // We need the index of these faces in their respective skeletons
            // to retrieve the data from the CausalTensor.
            let idx_alpha = p_skeleton
                .get_index(&front_simplex)
                .ok_or(TopologyError::SimplexNotFound())?;

            let idx_beta = q_skeleton
                .get_index(&back_simplex)
                .ok_or(TopologyError::SimplexNotFound())?;

            // 6. Fetch Values
            // self.data is a CausalTensor.
            let val_alpha = self
                .data
                .as_slice()
                .get(idx_alpha)
                .expect("Data/Skeleton mismatch");

            let val_beta = other
                .data
                .as_slice()
                .get(idx_beta)
                .expect("Data/Skeleton mismatch");

            // 7. Multiply (Geometric Product / Ring Product)
            // (α ⌣ β)(σ) = α(front) * β(back)
            let product = *val_alpha * *val_beta;

            result_values.push(product);
        }

        // 8. Construct Result
        Ok(Topology {
            complex: self.complex.clone(),
            grade: r,
            data: CausalTensor::new(result_values, vec![target_count]).unwrap(),
            cursor: 0,
        })
    }
}
