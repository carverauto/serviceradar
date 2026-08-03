/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Grade projection operations for CausalMultiField.
//!
//! Extracts specific grade components from the multivector field.

use crate::CausalMultiField;
use crate::traits::multi_vector::MultiVector;
use deep_causality_algebra::Field;

impl<T> CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    /// Projects the field onto grade k: ⟨F⟩_k.
    ///
    /// # Arguments
    /// * `k` - The grade to project onto (0=scalar, 1=vector, 2=bivector, etc.)
    pub fn grade_project(&self, k: usize) -> Self
    where
        T: std::ops::Neg<Output = T>,
    {
        // Download to Coefficients
        let mut mvs = self.to_coefficients();

        // Filter by grade
        for mv in &mut mvs {
            *mv = mv.grade_projection(k as u32);
        }

        // Upload back
        Self::from_coefficients(&mvs, self.shape, self.dx)
    }

    /// Extracts the scalar part (grade 0): ⟨F⟩₀.
    pub fn scalar_part(&self) -> Self
    where
        T: std::ops::Neg<Output = T>,
    {
        self.grade_project(0)
    }

    /// Extracts the vector part (grade 1): ⟨F⟩₁.
    pub fn vector_part(&self) -> Self
    where
        T: std::ops::Neg<Output = T>,
    {
        self.grade_project(1)
    }

    /// Extracts the bivector part (grade 2): ⟨F⟩₂.
    pub fn bivector_part(&self) -> Self
    where
        T: std::ops::Neg<Output = T>,
    {
        self.grade_project(2)
    }

    /// Extracts the trivector part (grade 3): ⟨F⟩₃.
    pub fn trivector_part(&self) -> Self
    where
        T: std::ops::Neg<Output = T>,
    {
        self.grade_project(3)
    }

    /// Extracts the pseudoscalar part (highest grade).
    pub fn pseudoscalar_part(&self) -> Self
    where
        T: std::ops::Neg<Output = T>,
    {
        let n = self.metric.dimension();
        self.grade_project(n)
    }
}
