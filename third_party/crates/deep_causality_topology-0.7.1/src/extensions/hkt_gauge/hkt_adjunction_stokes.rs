/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stokes Adjunction (d ⊣ ∂) for differential geometry.
//!
//! This module provides the adjunction between the exterior derivative (d)
//! and the boundary operator (∂), which encodes Stokes' theorem:
//! ⟨dω, C⟩ = ⟨ω, ∂C⟩
//!
//! This is the foundation for conservation laws and integration theory.

use crate::types::chain::Chain;
use crate::types::differential_form::DifferentialForm;
use crate::{BaseTopology, SimplicialComplex};
use deep_causality_haft::Pure; // Added Pure
use deep_causality_haft::{Adjunction, HKT, NoConstraint, Satisfies};
use deep_causality_num::Float;
use deep_causality_sparse::CsrMatrix;
use deep_causality_sparse::CsrMatrixWitness; // Added Witness
use std::collections::HashMap;
use std::sync::Arc;

/// Witness for the exterior derivative d: Ω^k → Ω^(k+1).
#[derive(Debug, Clone, Copy, Default)]
pub struct ExteriorDerivativeWitness;

impl HKT for ExteriorDerivativeWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = DifferentialForm<T>
    where
        T: Satisfies<NoConstraint>;
}

/// Witness for the boundary operator ∂: C_k → C_(k-1).
#[derive(Debug, Clone, Copy, Default)]
pub struct BoundaryWitness;

impl HKT for BoundaryWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = Chain<T>
    where
        T: Satisfies<NoConstraint>;
}

/// Context for Stokes theorem operations.
#[derive(Debug, Clone)]
pub struct StokesContext<T> {
    /// The simplicial complex defining the discrete topology.
    complex: Arc<SimplicialComplex<T>>,
}

impl<T> StokesContext<T> {
    /// Creates a new Stokes context from a simplicial complex.
    pub fn new(complex: SimplicialComplex<T>) -> Self {
        Self {
            complex: Arc::new(complex),
        }
    }

    /// Creates a new Stokes context from an Arc'd simplicial complex.
    pub fn from_arc(complex: Arc<SimplicialComplex<T>>) -> Self {
        Self { complex }
    }

    /// Returns a reference to the underlying simplicial complex.
    pub fn complex(&self) -> &SimplicialComplex<T> {
        &self.complex
    }

    /// Returns the Arc to the simplicial complex.
    pub fn complex_arc(&self) -> Arc<SimplicialComplex<T>> {
        Arc::clone(&self.complex)
    }

    /// Returns the dimension of the complex.
    pub fn dim(&self) -> usize {
        self.complex.dimension()
    }

    /// Returns the number of k-simplices.
    pub fn num_simplices(&self, k: usize) -> usize {
        if k < self.complex.skeletons().len() {
            self.complex.skeletons()[k].simplices().len()
        } else {
            0
        }
    }
}

/// Stokes Adjunction: d ⊣ ∂
///
/// # Mathematical Foundation
///
/// Stokes' theorem states that the exterior derivative d and boundary operator ∂
/// are adjoint under the integration pairing:
///
/// ⟨dω, C⟩ = ⟨ω, ∂C⟩
///
#[derive(Debug, Clone, Copy, Default)]
pub struct StokesAdjunction;

impl<T> Adjunction<ExteriorDerivativeWitness, BoundaryWitness, StokesContext<T>>
    for StokesAdjunction
where
    T: Satisfies<NoConstraint>,
{
    /// Unit: `A → R(L(A)) = Chain<DifferentialForm<A>>`
    ///
    /// Embeds a coefficient into a chain of forms.
    /// Semantically, this maps a value `a` to a 0-chain where each vertex has the 0-form `a`.
    fn unit<A>(ctx: &StokesContext<T>, a: A) -> Chain<DifferentialForm<A>>
    where
        A: Satisfies<NoConstraint> + Clone,
        DifferentialForm<A>: Satisfies<NoConstraint>,
    {
        // Dimension of the complex
        let dim = ctx.dim();

        // Create a 0-form with the single coefficient 'a'.
        // This represents a constant scalar field with value 'a' at a single point.
        let coefficients = vec![a];
        let form = DifferentialForm::from_coefficients(0, dim, coefficients);

        // Chain<DifferentialForm<A>> needs a SimplicialComplex<DifferentialForm<A>>.
        // We create a structural copy with empty hodge stars.
        let form_complex = SimplicialComplex::<DifferentialForm<A>> {
            skeletons: ctx.complex.skeletons.clone(),
            boundary_operators: ctx.complex.boundary_operators.clone(),
            coboundary_operators: ctx.complex.coboundary_operators.clone(),
            ..Default::default()
        };
        let arc_form_complex = Arc::new(form_complex);

        // Create sparse matrix for chain weights
        // We create a 0-chain (vertices) where the first vertex has weight 'form'.
        let inner_weights = <CsrMatrixWitness as Pure<CsrMatrixWitness>>::pure(form);

        // Chain grade 0
        Chain::new(arc_form_complex, 0, inner_weights)
    }

    /// Counit: `L(R(B)) = DifferentialForm<Chain<B>> → B`
    ///
    /// Extracts the integrated value from a form of chains.
    fn counit<B>(_ctx: &StokesContext<T>, lrb: DifferentialForm<Chain<B>>) -> B
    where
        B: Satisfies<NoConstraint> + Clone,
        Chain<B>: Satisfies<NoConstraint>,
    {
        // Integration: collapse form of chains to scalar (B).
        // The counit evaluation doesn't strictly depend on the topological context
        // if we assume the form and chain already encode the necessary structure.

        // Extract first chain from the form coefficients
        // Note: DifferentialForm cannot be empty by construction, so we can safely index [0].
        let chain = &lrb.coefficients().as_slice()[0];

        // Extract the first weight from the chain
        if let Some(val) = chain.weights().values().first() {
            return val.clone();
        }

        // Fallback/Panic if the chain is empty
        panic!("Counit requires at least one value in the form's chain to evaluate")
    }

    /// Left adjunct: (L(A) → B) → (A → R(B))
    ///
    /// Given `f: DifferentialForm<A> → B`, produce `g: A → Chain<B>`
    fn left_adjunct<A, B, Func>(ctx: &StokesContext<T>, a: A, f: Func) -> Chain<B>
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint>,
        DifferentialForm<A>: Satisfies<NoConstraint>,
        Func: Fn(DifferentialForm<A>) -> B,
    {
        // 1. Create a representative 0-form from 'a'
        let dim = ctx.dim();
        let form = DifferentialForm::from_coefficients(0, dim, vec![a]);

        // 2. Apply the morphism f to get the result in B
        let b = f(form);

        // 3. Wrap result 'b' into a 0-chain
        // Needs SimplicialComplex<B>
        let b_complex = SimplicialComplex::<B> {
            skeletons: ctx.complex.skeletons.clone(),
            boundary_operators: ctx.complex.boundary_operators.clone(),
            coboundary_operators: ctx.complex.coboundary_operators.clone(),
            ..Default::default()
        };
        let arc_b_complex = Arc::new(b_complex);

        // Create weights
        let weights = <CsrMatrixWitness as Pure<CsrMatrixWitness>>::pure(b);

        Chain::new(arc_b_complex, 0, weights)
    }

    /// Right adjunct: (A → R(B)) → (L(A) → B)
    ///
    /// Given `g: A → Chain<B>`, produce `f: DifferentialForm<A> → B`
    fn right_adjunct<A, B, Func>(_ctx: &StokesContext<T>, la: DifferentialForm<A>, mut f: Func) -> B
    where
        A: Satisfies<NoConstraint> + Clone,
        B: Satisfies<NoConstraint> + Clone,
        Chain<B>: Satisfies<NoConstraint>,
        Func: FnMut(A) -> Chain<B>,
    {
        // Extract value 'a' from the form 'la'
        // Note: DifferentialForm cannot be empty by construction.
        let a = &la.coefficients().as_slice()[0];

        // Apply morphism g (here 'f') to get Chain<B>
        let chain = f(a.clone());

        // Extract 'b' from the chain
        if let Some(b) = chain.weights().values().first() {
            return b.clone();
        }

        panic!("Right adjunct requires at least one value in the generated chain")
    }
}

// ============================================================================
// Production Operations (Generic over Float)
// ============================================================================

impl StokesAdjunction {
    /// Applies the exterior derivative to a discrete k-form.
    ///
    /// d: Ω^k → Ω^(k+1)
    ///
    /// Uses the coboundary matrix from the simplicial complex.
    pub fn exterior_derivative<T>(
        ctx: &StokesContext<T>,
        form: &DifferentialForm<T>,
    ) -> DifferentialForm<T>
    where
        T: Float + Default + From<f64>,
    {
        let k = form.degree();
        let dim = ctx.dim();

        // Cannot take derivative of top form
        if k >= dim {
            return DifferentialForm::zero(k + 1, form.dim());
        }

        // Get coboundary operator C_k = B_{k+1}^T
        let coboundary_ops = &ctx.complex().coboundary_operators;
        if k >= coboundary_ops.len() {
            return DifferentialForm::zero(k + 1, form.dim());
        }

        let coboundary = &coboundary_ops[k];
        let coeffs = form.coefficients().as_slice();

        // Get size from shape
        let shape = coboundary.shape();
        let nrows = shape.0;

        let mut result_coeffs: Vec<T> = Vec::with_capacity(nrows);

        // For each row (output simplex), compute the sum
        for row_idx in 0..nrows {
            let mut sum = T::zero();

            // Get the row slice using CSR structure
            let row_start = coboundary.row_indices()[row_idx];
            let row_end = coboundary.row_indices()[row_idx + 1];

            for idx in row_start..row_end {
                let col = coboundary.col_indices()[idx];
                let sign = coboundary.values()[idx]; // i8, -1 or 1

                if col < coeffs.len() {
                    // Convert sign to T
                    let sign_t = if sign > 0 { T::one() } else { -T::one() };
                    // Float usually implies Add, Mul. Summing requires explicit Add.
                    // But Float implies Num implies Add.
                    sum += coeffs[col] * sign_t;
                }
            }
            result_coeffs.push(sum);
        }

        DifferentialForm::from_coefficients(k + 1, form.dim(), result_coeffs)
    }

    /// Applies the boundary operator to a k-chain.
    ///
    /// ∂: C_k → C_(k-1)
    ///
    /// Uses the boundary matrix from the simplicial complex.
    pub fn boundary<T>(ctx: &StokesContext<T>, chain: &Chain<T>) -> Chain<T>
    where
        T: Float + Default,
    {
        let k = chain.grade();

        // Boundary of 0-chain is empty
        if k == 0 {
            let empty_weights: CsrMatrix<T> = CsrMatrix::new();
            return Chain::new(ctx.complex_arc(), 0, empty_weights);
        }

        // Get boundary operator B_k: C_k -> C_{k-1}
        let boundary_ops = &ctx.complex().boundary_operators;
        if k > boundary_ops.len() {
            let empty_weights: CsrMatrix<T> = CsrMatrix::new();
            return Chain::new(ctx.complex_arc(), k - 1, empty_weights);
        }

        let boundary_op = &boundary_ops[k];
        let shape = boundary_op.shape();
        let nrows = shape.0; // num_(k-1)_simplices

        let chain_weights = chain.weights();
        let row_indices = chain_weights.row_indices();
        let col_indices = chain_weights.col_indices();
        let values = chain_weights.values();

        if row_indices.is_empty() {
            let empty_weights: CsrMatrix<T> = CsrMatrix::default();
            return Chain::new(ctx.complex_arc(), k - 1, empty_weights);
        }

        // Optimization: Collect chain weights into a HashMap for O(1) lookups
        let chain_map: HashMap<usize, T> = col_indices
            .iter()
            .zip(values.iter())
            .map(|(&c, v)| (c, *v))
            .collect();

        let mut result_triplets: Vec<(usize, usize, T)> = Vec::new();

        // Iterate over each row of the boundary matrix (each (k-1)-simplex)
        for row_idx in 0..nrows {
            let mut sum = T::zero();
            let row_start = boundary_op.row_indices()[row_idx];
            let row_end = boundary_op.row_indices()[row_idx + 1];

            // Dot product: row(B) . v
            for idx in row_start..row_end {
                let col = boundary_op.col_indices()[idx]; // index of k-simplex (j)
                let sign = boundary_op.values()[idx]; // B_ij (orientation)

                if let Some(val) = chain_map.get(&col) {
                    let sign_t = if sign > 0 { T::one() } else { -T::one() };
                    sum += *val * sign_t;
                }
            }

            if sum != T::zero() {
                result_triplets.push((0, row_idx, sum));
            }
        }

        let num_k_minus_1_simplices = ctx.num_simplices(k - 1);
        let result_matrix = CsrMatrix::from_triplets(1, num_k_minus_1_simplices, &result_triplets)
            .unwrap_or_else(|_| CsrMatrix::new());

        Chain::new(ctx.complex_arc(), k - 1, result_matrix)
    }

    /// Integrates a k-form over a k-chain: ⟨ω, C⟩ = ∫_C ω
    pub fn integrate<T>(form: &DifferentialForm<T>, chain: &Chain<T>) -> T
    where
        T: Float + Default,
    {
        if form.degree() != chain.grade() {
            return T::zero();
        }

        let coeffs = form.coefficients().as_slice();
        let weights = chain.weights();
        let mut result = T::zero();

        let col_indices = weights.col_indices();
        let values = weights.values();

        for (idx, &col) in col_indices.iter().enumerate() {
            if col < coeffs.len() {
                result += values[idx] * coeffs[col];
            }
        }

        result
    }
}
