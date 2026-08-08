/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// multi_vector

use crate::CausalMultiVectorError;
use core::ops::{AddAssign, Neg, SubAssign};
use deep_causality_algebra::Field;
// Added Complex, DivisionAlgebra

pub trait MultiVector<T> {
    // --- Fundamental Projections ---

    /// Projects the multivector onto a specific grade $k$.
    ///
    /// $$ \langle A \rangle_k = \sum_{I : |I|=k} a_I e_I $$
    fn grade_projection(&self, k: u32) -> Self
    where
        T: Field + Copy + Clone;

    // --- Geometric Operations ---

    /// Computes the reverse of the multivector, denoted $\tilde{A}$ or $A^\dagger$.
    ///
    /// Reverses the order of vectors in each basis blade.
    /// $$ \tilde{A} = \sum_{k=0}^N (-1)^{k(k-1)/2} \langle A \rangle_k $$
    fn reversion(&self) -> Self
    where
        T: Field + Copy + Clone + Neg<Output = T>;

    /// Computes the squared magnitude (squared norm) of the multivector.
    fn squared_magnitude(&self) -> T
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>;

    /// Computes the inverse of the multivector $A^{-1}$.
    fn inverse(&self) -> Result<Self, CausalMultiVectorError>
    where
        T: Field
            + Copy
            + Clone
            + AddAssign
            + SubAssign
            + Neg<Output = T>
            + core::ops::Div<Output = T>
            + PartialEq,
        Self: Sized;

    /// Computes the dual of the multivector $A^*$.
    fn dual(&self) -> Result<Self, CausalMultiVectorError>
    where
        T: Field
            + Copy
            + Clone
            + AddAssign
            + SubAssign
            + Neg<Output = T>
            + core::ops::Div<Output = T>
            + PartialEq,
        Self: Sized;

    // --- Products ---

    /// Computes the Geometric Product $AB$.
    ///
    /// This is the fundamental operation of Clifford Algebra, combining
    /// the inner (contraction) and outer (expansion) products.
    ///
    /// $$ AB = A \cdot B + A \wedge B $$
    ///
    /// It is associative and distributive over addition.
    fn geometric_product(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>;

    /// Computes the outer product (wedge product) $A \wedge B$.
    ///
    /// The outer product of two multivectors of grades $r$ and $s$ is the grade $r+s$ part of their geometric product.
    /// $$ A \wedge B = \langle AB \rangle_{r+s} $$
    ///
    /// For basis blades $e_I$ and $e_J$, $e_I \wedge e_J$ is non-zero only if $I \cap J = \emptyset$.
    fn outer_product(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign;
    /// Computes the inner product (left contraction) $A \cdot B$ (or $A \rfloor B$).
    ///
    /// The inner product of a grade $r$ multivector $A$ and a grade $s$ multivector $B$ is the grade $s-r$ part of their geometric product.
    /// $$ A \cdot B = \langle AB \rangle_{s-r} $$
    ///
    /// For basis blades $e_I$ and $e_J$, $e_I \cdot e_J$ is non-zero only if $I \subseteq J$.
    fn inner_product(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign;

    /// Computes the Lie Bracket commutator $[A, B] = AB - BA$.
    ///
    /// This is the standard definition for Lie Algebras (Particle Physics).
    /// For orthogonal basis vectors: $[e_1, e_2] = 2e_{12}$.
    fn commutator_lie(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>;

    /// Computes the Geometric Algebra commutator product $A \times B = \frac{1}{2}(AB - BA)$.
    ///
    /// This projects the result onto the subspace orthogonal to the inputs.
    /// For orthogonal basis vectors: $e_1 \times e_2 = e_{12}$.
    ///
    /// **Requirement:** Type `T` must support division by 2 (e.g. `1 + 1`).
    fn commutator_geometric(&self, rhs: &Self) -> Self
    where
        T: Field
            + Copy
            + Clone
            + AddAssign
            + SubAssign
            + Neg<Output = T>
            + core::ops::Div<Output = T>;

    // --- CoMonadic Ops ---

    /// Cyclically shifts the basis coefficients.
    /// This effectively changes the "viewpoint" of the algebra,
    /// making the coefficient at `index` the new scalar (index 0).
    ///
    /// Used for Comonadic 'extend' operations.
    fn basis_shift(&self, index: usize) -> Self
    where
        T: Clone;
}
