/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Differential forms for de Rham cohomology and Stokes theorem.
//!
//! A differential k-form is an antisymmetric tensor field that can be integrated
//! over k-dimensional submanifolds.

use deep_causality_tensor::CausalTensor;
use std::marker::PhantomData;

/// A differential k-form on a manifold.
///
/// Differential forms are the natural objects to integrate over manifolds.
/// A k-form can be integrated over a k-dimensional submanifold.
///
/// # Type Parameter
///
/// * `T` - The coefficient scalar type
///
/// # Mathematical Structure
///
/// A k-form ω is a totally antisymmetric (0,k)-tensor:
/// ω = ω_{i₁...iₖ} dx^{i₁} ∧ ... ∧ dx^{iₖ}
///
/// # Examples
///
/// - 0-form: scalar function f
/// - 1-form: covector A_μ dx^μ (e.g., electromagnetic potential)
/// - 2-form: F_μν dx^μ ∧ dx^ν (e.g., electromagnetic field)
/// - 3-form: volume element in 3D
/// - 4-form: Hodge dual of 0-form in 4D
#[derive(Debug, Clone, PartialEq)]
pub struct DifferentialForm<T> {
    /// The form degree (0-form, 1-form, 2-form, etc.).
    degree: usize,

    /// The manifold dimension.
    dim: usize,

    /// Antisymmetric coefficient tensor.
    /// For discrete forms: vector indexed by simplex number.
    /// For smooth forms: antisymmetric tensor of shape [n, n, ..., n] (k times).
    coefficients: CausalTensor<T>,

    /// Phantom for T.
    _phantom: PhantomData<T>,
}

// ============================================================================
// Constructors (Unconstrained)
// ============================================================================

impl<T> DifferentialForm<T> {
    /// Creates a differential form from a tensor without requiring Default.
    ///
    /// This is the minimal constructor for use in generic contexts where
    /// T may not implement Default.
    pub fn from_tensor(degree: usize, dim: usize, coefficients: CausalTensor<T>) -> Self {
        Self {
            degree,
            dim,
            coefficients,
            _phantom: PhantomData,
        }
    }

    /// Creates a form from a vector of coefficients.
    ///
    /// # Arguments
    ///
    /// * `degree` - The form degree
    /// * `dim` - The manifold dimension
    /// * `coeffs` - The coefficient values
    pub fn from_coefficients(degree: usize, dim: usize, coeffs: Vec<T>) -> Self {
        let num_components = coeffs.len().max(1);
        let coefficients = CausalTensor::from_vec(coeffs, &[num_components]);

        Self {
            degree,
            dim,
            coefficients,
            _phantom: PhantomData,
        }
    }
}

// ============================================================================
// Constructors (Require Clone + Default)
// ============================================================================

impl<T: Clone + Default> DifferentialForm<T> {
    /// Creates a new differential form.
    ///
    /// # Arguments
    ///
    /// * `degree` - The form degree (k for k-form)
    /// * `dim` - The manifold dimension
    /// * `coefficients` - The coefficient tensor
    pub fn new(degree: usize, dim: usize, coefficients: CausalTensor<T>) -> Self {
        Self::from_tensor(degree, dim, coefficients)
    }

    /// Creates a zero k-form.
    ///
    /// # Arguments
    ///
    /// * `degree` - The form degree
    /// * `dim` - The manifold dimension
    pub fn zero(degree: usize, dim: usize) -> Self
    where
        T: From<f64>,
    {
        // For a k-form, we have C(n,k) independent components
        let num_components = binomial(dim, degree).max(1);
        let data = vec![T::from(0.0); num_components];
        let coefficients = CausalTensor::from_vec(data, &[num_components]);

        Self {
            degree,
            dim,
            coefficients,
            _phantom: PhantomData,
        }
    }

    /// Creates a constant 0-form with a single value.
    ///
    /// # Arguments
    ///
    /// * `degree` - The form degree (typically 0 for constants)
    /// * `dim` - The manifold dimension
    /// * `value` - The constant value
    pub fn constant(degree: usize, dim: usize, value: T) -> Self {
        let num_components = binomial(dim, degree).max(1);
        let data = vec![value; num_components];
        let coefficients = CausalTensor::from_vec(data, &[num_components]);

        Self {
            degree,
            dim,
            coefficients,
            _phantom: PhantomData,
        }
    }

    /// Creates a form from a closure.
    ///
    /// # Arguments
    ///
    /// * `degree` - The form degree
    /// * `dim` - The manifold dimension
    /// * `generator` - Function that takes index and returns coefficient
    pub fn from_generator<F>(degree: usize, dim: usize, generator: F) -> Self
    where
        F: FnMut(usize) -> T,
    {
        let num_components = binomial(dim, degree).max(1);
        let data: Vec<T> = (0..num_components).map(generator).collect();
        let coefficients = CausalTensor::from_vec(data, &[num_components]);

        Self {
            degree,
            dim,
            coefficients,
            _phantom: PhantomData,
        }
    }
}

// ============================================================================
// Getters
// ============================================================================

impl<T> DifferentialForm<T> {
    /// Returns the form degree (k for k-form).
    #[inline]
    pub fn degree(&self) -> usize {
        self.degree
    }

    /// Returns the manifold dimension.
    #[inline]
    pub fn dim(&self) -> usize {
        self.dim
    }

    /// Returns a reference to the coefficient tensor.
    #[inline]
    pub fn coefficients(&self) -> &CausalTensor<T> {
        &self.coefficients
    }

    /// Returns a mutable reference to the coefficient tensor.
    #[inline]
    pub fn coefficients_mut(&mut self) -> &mut CausalTensor<T> {
        &mut self.coefficients
    }

    /// Checks if this is a 0-form (scalar function).
    #[inline]
    pub fn is_scalar(&self) -> bool {
        self.degree == 0
    }

    /// Checks if this is a 1-form (covector).
    #[inline]
    pub fn is_covector(&self) -> bool {
        self.degree == 1
    }

    /// Checks if this is a top form (n-form in n dimensions).
    #[inline]
    pub fn is_top_form(&self) -> bool {
        self.degree == self.dim
    }

    /// Returns the number of independent components.
    ///
    /// For a k-form in n dimensions: C(n, k)
    #[inline]
    pub fn num_components(&self) -> usize {
        binomial(self.dim, self.degree)
    }

    /// Gets a coefficient by index.
    #[inline]
    pub fn get(&self, idx: usize) -> Option<&T> {
        self.coefficients.as_slice().get(idx)
    }
}

// ============================================================================
// Operations
// ============================================================================

impl<T: Clone> DifferentialForm<T> {
    /// Maps a function over all coefficients.
    pub fn map<U: Clone, F>(&self, f: F) -> DifferentialForm<U>
    where
        F: FnMut(&T) -> U,
    {
        let new_coeffs: Vec<U> = self.coefficients.as_slice().iter().map(f).collect();
        let coefficients = CausalTensor::from_vec(new_coeffs, self.coefficients.shape());

        DifferentialForm {
            degree: self.degree,
            dim: self.dim,
            coefficients,
            _phantom: PhantomData,
        }
    }
}

impl<T: Clone + Default + std::ops::Add<Output = T>> DifferentialForm<T> {
    /// Adds two forms of the same degree.
    ///
    /// # Panics
    ///
    /// Panics if forms have different degrees or dimensions.
    pub fn add(&self, other: &Self) -> Self {
        assert_eq!(self.degree, other.degree, "Form degrees must match");
        assert_eq!(self.dim, other.dim, "Form dimensions must match");

        let a = self.coefficients.as_slice();
        let b = other.coefficients.as_slice();
        let new_coeffs: Vec<T> = a
            .iter()
            .zip(b.iter())
            .map(|(x, y)| x.clone() + y.clone())
            .collect();

        Self::from_coefficients(self.degree, self.dim, new_coeffs)
    }
}

impl<T: Clone + Default + std::ops::Mul<f64, Output = T>> DifferentialForm<T> {
    /// Scales the form by a scalar.
    pub fn scale(&self, scalar: f64) -> Self {
        let new_coeffs: Vec<T> = self
            .coefficients
            .as_slice()
            .iter()
            .map(|x| x.clone() * scalar)
            .collect();

        Self::from_coefficients(self.degree, self.dim, new_coeffs)
    }
}

/// Computes binomial coefficient C(n, k) = n! / (k! (n-k)!)
fn binomial(n: usize, k: usize) -> usize {
    if k > n {
        return 0;
    }
    if k == 0 || k == n {
        return 1;
    }
    // Use the multiplicative formula to avoid overflow
    let k = k.min(n - k);
    let mut result = 1usize;
    for i in 0..k {
        result = result * (n - i) / (i + 1);
    }
    result
}
