/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Implements various algebraic traits for `Octonion<T>`.
///
/// | Type | `Distributive` | `Associative` | `Commutative` | Trait |
/// | :--- | :---: | :---: | :---: | :--- |
/// | **Octonion** | ✅ | ❌ | ❌ | `DivisionAlgebra` |
///
/// This file is responsible for binding the `Octonion` type to the algebraic
/// hierarchy defined in the `deep_causality_num/src/algebra/` module.
/// It explicitly states the algebraic properties of octonions, such as being
/// a distributive and abelian group, and a division algebra, while correctly
/// identifying their non-associative and non-commutative nature.
use crate::{AbelianGroup, Distributive, DivisionAlgebra, Octonion, RealField};

// Marker Traits
/// Implements the `Distributive` marker trait for `Octonion`.
///
/// This signifies that multiplication of `Octonion`s distributes over addition,
/// i.e., `a * (b + c) = (a * b) + (a * c)`. This property holds for octonions.
impl<T: RealField> Distributive for Octonion<T> {}

// DO NOT IMPLEMENT `Associative` as octonion multiplication is non-associative.
// DO NOT IMPLEMENT `Commutative` as octonion multiplication is non-commutative.

// Octonion addition is component-wise and commutative.
/// Implements the `AbelianGroup` trait for `Octonion`.
///
/// This signifies that `Octonion`s form an abelian (commutative) group under addition.
/// Addition is component-wise, ensuring commutativity and associativity.
impl<T: RealField> AbelianGroup for Octonion<T> {}

// Octonions are a Division Algebra, but NOT associative.
// The blanket impl for `Algebra<T>` will apply, since we can satisfy its
// bounds: `Module<T> + Mul<...> + MulAssign + One + Distributive`.
/// Implements the `DivisionAlgebra` trait for `Octonion`.
///
/// Octonions form a non-associative division algebra over the real numbers.
/// This trait provides methods for `conjugate`, `norm_sqr`, and `inverse`,
/// which are fundamental to division algebras.
impl<T: RealField> DivisionAlgebra<T> for Octonion<T> {
    /// Computes the conjugate of the octonion.
    ///
    /// The conjugate of an octonion `s + e₁i + ... + e₇p` is `s - e₁i - ... - e₇p`.
    /// The scalar part remains unchanged, while all imaginary parts are negated.
    ///
    /// # Returns
    /// A new octonion representing the conjugate of `self`.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, DivisionAlgebra};
    ///
    /// let o = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
    /// let conj_o = o.conjugate();
    /// assert_eq!(conj_o.s, 1.0);
    /// assert_eq!(conj_o.e1, -2.0);
    /// assert_eq!(conj_o.e7, -8.0);
    /// ```
    fn conjugate(&self) -> Self {
        self._conjugate_impl()
    }

    /// Computes the square of the norm (magnitude) of the octonion.
    ///
    /// The norm squared is calculated as the sum of the squares of all its components:
    /// `s² + e₁² + e₂² + e₃² + e₄² + e₅² + e₆² + e₇²`.
    ///
    /// # Returns
    /// The scalar value `F` representing the squared norm.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, DivisionAlgebra};
    ///
    /// let o = Octonion::new(1.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// assert_eq!(o.norm_sqr(), 5.0); // 1*1 + 2*2 = 5
    /// ```
    fn norm_sqr(&self) -> T {
        self._norm_sqr_impl()
    }

    /// Computes the inverse of the octonion.
    ///
    /// The inverse `o⁻¹` of an octonion `o` is defined as `conjugate(o) / norm_sqr(o)`.
    ///
    /// # Returns
    /// A new `Octonion` representing the inverse of `self`. If `norm_sqr()` is zero,
    /// an octonion with `NaN` components is returned to indicate an undefined inverse.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{One, Octonion, Zero, DivisionAlgebra};
    ///
    /// let o = Octonion::new(1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0); // 1 + e1
    /// let inverse_o = o.inverse();
    /// // (1 + e1) * (0.5 - 0.5e1) = 0.5 - 0.5e1 + 0.5e1 - 0.5e1*e1 = 0.5 + 0.5 = 1
    /// let expected_inverse = Octonion::new(0.5, -0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    ///
    /// // Use approximate equality due to floating point arithmetic
    /// assert!((inverse_o.s - expected_inverse.s) < 1e-9);
    /// assert!((inverse_o.e1 - expected_inverse.e1) < 1e-9);
    ///
    /// let zero_o = Octonion::<f64>::zero();
    /// let inv_zero = zero_o.inverse();
    /// assert!(inv_zero.s.is_nan());
    /// ```
    fn inverse(&self) -> Self {
        self._inverse_impl()
    }
}

// Octonions do not form a multiplicative group because multiplication is not associative.
// However, non-zero octonions do have multiplicative inverses.
// The `MulGroup` trait requires associativity, so it is not implemented.
