/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{DivisionAlgebra, Octonion, One, RealField, Zero};
use core::iter::{Product, Sum};
use core::ops::{Add, Div, Mul, Sub};
use core::ops::{AddAssign, DivAssign, MulAssign, SubAssign};

/// Implements the `Sum` trait for `Octonion`, allowing an iterator of octonions to be summed.
///
/// The sum is performed by iteratively adding each octonion in the iterator.
///
/// # Arguments
/// * `iter` - An iterator that yields `Octonion<F>` values.
///
/// # Returns
/// A single `Octonion` representing the sum of all octonions in the iterator.
/// If the iterator is empty, it returns the zero octonion.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
/// use deep_causality_num::Zero;
///
/// let o1 = Octonion::new(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
/// let o2 = Octonion::new(2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0);
/// let o3 = Octonion::new(3.0, 3.0, 3.0, 3.0, 3.0, 3.0, 3.0, 3.0);
/// let octonions = vec![o1, o2, o3];
/// let sum: Octonion<f64> = octonions.into_iter().sum();
/// assert_eq!(sum.s, 6.0);
/// assert_eq!(sum.e1, 6.0);
///
/// let empty_vec: Vec<Octonion<f64>> = Vec::new();
/// let empty_sum: Octonion<f64> = empty_vec.into_iter().sum();
/// assert_eq!(empty_sum, Octonion::zero());
/// ```
impl<F: RealField> Sum for Octonion<F> {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Octonion::zero(), |acc, x| acc + x)
    }
}

/// Implements the `Product` trait for `Octonion`, allowing an iterator of octonions to be multiplied.
///
/// The product is performed by iteratively multiplying each octonion in the iterator.
/// Due to non-associativity, the order of multiplication matters. This implementation
/// performs sequential left-to-right multiplication.
///
/// # Arguments
/// * `iter` - An iterator that yields `Octonion<F>` values.
///
/// # Returns
/// A single `Octonion` representing the product of all octonions in the iterator.
/// If the iterator is empty, it returns the identity octonion (1).
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
/// use deep_causality_num::One;
///
/// let o_one = Octonion::one();
/// let e1 = Octonion::new(0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// let e2 = Octonion::new(0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// let e3 = Octonion::new(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0);
///
/// let octonions = vec![o_one, e1, e2];
/// let product: Octonion<f64> = octonions.into_iter().product();
/// assert_eq!(product, e3); // (1 * e1) * e2 = e1 * e2 = e3
///
/// let empty_vec: Vec<Octonion<f64>> = Vec::new();
/// let empty_product: Octonion<f64> = empty_vec.into_iter().product();
/// assert_eq!(empty_product, Octonion::one());
/// ```
impl<F: RealField> Product for Octonion<F> {
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Octonion::one(), |acc, x| acc * x)
    }
}

/// Implements the addition operator (`+`) for two `Octonion` numbers.
///
/// Octonion addition is performed component-wise:
/// `(s₁ + v₁) + (s₂ + v₂) = (s₁ + s₂) + (v₁ + v₂)`
///
/// # Arguments
/// * `self` - The left-hand side `Octonion`.
/// * `rhs` - The right-hand side `Octonion`.
///
/// # Returns
/// A new `Octonion` representing the sum of `self` and `rhs`.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let o1 = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// let o2 = Octonion::new(9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0);
/// let sum = o1 + o2;
/// assert_eq!(sum.s, 10.0);
/// assert_eq!(sum.e1, 12.0);
/// // ... and so on for other components
/// ```
impl<F: RealField> Add for Octonion<F> {
    type Output = Self;
    fn add(self, rhs: Self) -> Self::Output {
        Self {
            s: self.s + rhs.s,
            e1: self.e1 + rhs.e1,
            e2: self.e2 + rhs.e2,
            e3: self.e3 + rhs.e3,
            e4: self.e4 + rhs.e4,
            e5: self.e5 + rhs.e5,
            e6: self.e6 + rhs.e6,
            e7: self.e7 + rhs.e7,
        }
    }
}

/// Implements the addition assignment operator (`+=`) for two `Octonion` numbers.
///
/// Each component of `self` is added to the corresponding component of `other`.
/// `self = self + other`
///
/// # Arguments
/// * `self` - The left-hand side `Octonion` to be modified.
/// * `other` - The right-hand side `Octonion` to add.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let mut o1 = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// let o2 = Octonion::new(9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0);
/// o1 += o2;
/// assert_eq!(o1.s, 10.0);
/// assert_eq!(o1.e1, 12.0);
/// ```
impl<F: RealField> AddAssign for Octonion<F> {
    fn add_assign(&mut self, other: Self) {
        self.s += other.s;
        self.e1 += other.e1;
        self.e2 += other.e2;
        self.e3 += other.e3;
        self.e4 += other.e4;
        self.e5 += other.e5;
        self.e6 += other.e6;
        self.e7 += other.e7;
    }
}

/// Implements the subtraction operator (`-`) for two `Octonion` numbers.
///
/// Octonion subtraction is performed component-wise:
/// `(s₁ + v₁) - (s₂ + v₂) = (s₁ - s₂) + (v₁ - v₂)`
///
/// # Arguments
/// * `self` - The left-hand side `Octonion`.
/// * `rhs` - The right-hand side `Octonion`.
///
/// # Returns
/// A new `Octonion` representing the difference between `self` and `rhs`.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let o1 = Octonion::new(9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0);
/// let o2 = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// let diff = o1 - o2;
/// assert_eq!(diff.s, 8.0);
/// assert_eq!(diff.e1, 8.0);
/// // ... and so on for other components
/// ```
impl<F: RealField> Sub for Octonion<F> {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self::Output {
        Self {
            s: self.s - rhs.s,
            e1: self.e1 - rhs.e1,
            e2: self.e2 - rhs.e2,
            e3: self.e3 - rhs.e3,
            e4: self.e4 - rhs.e4,
            e5: self.e5 - rhs.e5,
            e6: self.e6 - rhs.e6,
            e7: self.e7 - rhs.e7,
        }
    }
}

/// Implements the subtraction assignment operator (`-=`) for two `Octonion` numbers.
///
/// Each component of `other` is subtracted from the corresponding component of `self`.
/// `self = self - other`
///
/// # Arguments
/// * `self` - The left-hand side `Octonion` to be modified.
/// * `other` - The right-hand side `Octonion` to subtract.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let mut o1 = Octonion::new(9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0);
/// let o2 = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// o1 -= o2;
/// assert_eq!(o1.s, 8.0);
/// assert_eq!(o1.e1, 8.0);
/// ```
impl<F: RealField> SubAssign for Octonion<F> {
    fn sub_assign(&mut self, other: Self) {
        self.s -= other.s;
        self.e1 -= other.e1;
        self.e2 -= other.e2;
        self.e3 -= other.e3;
        self.e4 -= other.e4;
        self.e5 -= other.e5;
        self.e6 -= other.e6;
        self.e7 -= other.e7;
    }
}

/// Implements the multiplication operator (`*`) for two `Octonion` numbers.
///
/// Octonion multiplication is non-commutative and non-associative, following
/// the rules of the Cayley-Dickson construction. The product is calculated
/// based on the Fano plane relationships between the imaginary units.
///
/// The formula for the product of two octonions `(s₁, e₁, e₂, e₃, e₄, e₅, e₆, e₇)`
/// and `(s₂, f₁, f₂, f₃, f₄, f₅, f₆, f₇)` is complex and involves all components.
///
/// # Arguments
/// * `self` - The left-hand side `Octonion`.
/// * `rhs` - The right-hand side `Octonion`.
///
/// # Returns
/// A new `Octonion` representing the product of `self` and `rhs`.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
/// use deep_causality_num::Zero;
///
/// let e1 = Octonion::new(0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// let e2 = Octonion::new(0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// let e3 = Octonion::new(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0);
///
/// // Example of non-commutative multiplication
/// assert_eq!(e1 * e2, e3);
/// assert_eq!(e2 * e1, -e3);
///
/// // Example of an imaginary unit squared
/// let neg_one = Octonion::new(-1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// assert_eq!(e1 * e1, neg_one);
/// ```
impl<F: RealField> Mul for Octonion<F> {
    type Output = Self;
    fn mul(self, rhs: Self) -> Self::Output {
        let s_res = self.s * rhs.s
            - self.e1 * rhs.e1
            - self.e2 * rhs.e2
            - self.e3 * rhs.e3
            - self.e4 * rhs.e4
            - self.e5 * rhs.e5
            - self.e6 * rhs.e6
            - self.e7 * rhs.e7;

        let e1_res = self.s * rhs.e1 + self.e1 * rhs.s + self.e2 * rhs.e3 - self.e3 * rhs.e2
            + self.e4 * rhs.e5
            - self.e5 * rhs.e4
            + self.e6 * rhs.e7
            - self.e7 * rhs.e6;

        let e2_res = self.s * rhs.e2 + self.e2 * rhs.s + self.e3 * rhs.e1 - self.e1 * rhs.e3
            + self.e4 * rhs.e6
            - self.e6 * rhs.e4
            + self.e7 * rhs.e5
            - self.e5 * rhs.e7;

        let e3_res = self.s * rhs.e3 + self.e3 * rhs.s + self.e1 * rhs.e2 - self.e2 * rhs.e1
            + self.e4 * rhs.e7
            - self.e7 * rhs.e4
            + self.e5 * rhs.e6
            - self.e6 * rhs.e5;

        let e4_res = self.s * rhs.e4 + self.e4 * rhs.s - self.e1 * rhs.e5
            + self.e5 * rhs.e1
            + self.e2 * rhs.e6
            - self.e6 * rhs.e2
            - self.e3 * rhs.e7
            + self.e7 * rhs.e3;

        let e5_res = self.s * rhs.e5 + self.e5 * rhs.s + self.e1 * rhs.e4
            - self.e4 * rhs.e1
            - self.e2 * rhs.e7
            + self.e7 * rhs.e2
            - self.e3 * rhs.e6
            + self.e6 * rhs.e3;

        let e6_res = self.s * rhs.e6 + self.e6 * rhs.s + self.e1 * rhs.e7 - self.e7 * rhs.e1
            + self.e2 * rhs.e4
            - self.e4 * rhs.e2
            + self.e3 * rhs.e5
            - self.e5 * rhs.e3;

        let e7_res = self.s * rhs.e7 + self.e7 * rhs.s - self.e1 * rhs.e6 + self.e6 * rhs.e1
            - self.e2 * rhs.e5
            + self.e5 * rhs.e2
            + self.e3 * rhs.e4
            - self.e4 * rhs.e3;
        Self::new(
            s_res, e1_res, e2_res, e3_res, e4_res, e5_res, e6_res, e7_res,
        )
    }
}

/// Implements the multiplication assignment operator (`*=`) for an `Octonion` and another `Octonion`.
///
/// `self = self * other`
///
/// # Arguments
/// * `self` - The left-hand side `Octonion` to be modified.
/// * `other` - The right-hand side `Octonion` to multiply by.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
/// use deep_causality_num::Zero;
///
/// let mut o = Octonion::new(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0); // 1
/// let e1 = Octonion::new(0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// o *= e1; // o becomes e1
/// assert_eq!(o, e1);
/// ```
impl<F: RealField> MulAssign for Octonion<F> {
    fn mul_assign(&mut self, other: Self) {
        *self = *self * other;
    }
}

/// Implements scalar multiplication for an `Octonion` by a scalar of type `F`.
///
/// Each component of the octonion is multiplied by the scalar value.
/// `o * scalar = (s * scalar, e₁ * scalar, ..., e₇ * scalar)`
///
/// # Arguments
/// * `self` - The `Octonion` to be multiplied.
/// * `scalar` - The scalar value of type `F`.
///
/// # Returns
/// A new `Octonion` representing the product of `self` and `scalar`.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let o = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// let scalar = 2.0;
/// let prod = o * scalar;
/// assert_eq!(prod.s, 2.0);
/// assert_eq!(prod.e1, 4.0);
/// // ... and so on for other components
/// ```
impl<F: RealField> Mul<F> for Octonion<F> {
    type Output = Self;
    fn mul(self, scalar: F) -> Self {
        Octonion {
            s: self.s * scalar,
            e1: self.e1 * scalar,
            e2: self.e2 * scalar,
            e3: self.e3 * scalar,
            e4: self.e4 * scalar,
            e5: self.e5 * scalar,
            e6: self.e6 * scalar,
            e7: self.e7 * scalar,
        }
    }
}

/// Implements scalar multiplication assignment (`*=`) for an `Octonion` by a scalar of type `F`.
///
/// Each component of `self` is multiplied by the `scalar` value.
/// `self = self * scalar`
///
/// # Arguments
/// * `self` - The `Octonion` to be modified.
/// * `scalar` - The scalar value of type `F`.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let mut o = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// let scalar = 2.0;
/// o *= scalar;
/// assert_eq!(o.s, 2.0);
/// assert_eq!(o.e1, 4.0);
/// ```
impl<F: RealField> MulAssign<F> for Octonion<F> {
    fn mul_assign(&mut self, scalar: F) {
        self.s *= scalar;
        self.e1 *= scalar;
        self.e2 *= scalar;
        self.e3 *= scalar;
        self.e4 *= scalar;
        self.e5 *= scalar;
        self.e6 *= scalar;
        self.e7 *= scalar;
    }
}

/// Implements the division operator (`/`) for two `Octonion` numbers.
///
/// Octonion division is defined as multiplication by the inverse of the divisor:
/// `self / other = self * other.inverse()`.
///
/// Due to the non-associativity of octonions, there are distinct left and right
/// division operations. This implementation performs right division (equivalent to
/// `self * other⁻¹`).
///
/// # Arguments
/// * `self` - The dividend `Octonion`.
/// * `other` - The divisor `Octonion`.
///
/// # Returns
/// A new `Octonion` representing the quotient of `self` divided by `other`.
/// If `other` is a zero octonion, the result will have NaN components.
///
/// # Notes
/// The `clippy::suspicious_arithmetic_impl` lint is allowed here because the
/// implementation delegates to `Mul` and `inverse()`, which correctly handles
/// the complex nature of octonion division.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
/// use deep_causality_num::{One, Zero};
///
/// let o1 = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
/// let o_one = Octonion::one(); // Identity octonion (1 + 0e1 + ...)
/// let result = o1 / o_one;
/// assert_eq!(result, o1);
///
/// // Division of imaginary units
/// let e1 = Octonion::new(0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// let e2 = Octonion::new(0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// let e3 = Octonion::new(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0);
/// let neg_e3 = -e3;
/// assert_eq!(e1 / e2, neg_e3);
/// ```
#[allow(clippy::suspicious_arithmetic_impl)]
impl<F: RealField> Div for Octonion<F> {
    type Output = Self;
    fn div(self, other: Self) -> Self {
        self * other.inverse()
    }
}

/// Implements the division assignment operator (`/=`) for an `Octonion` and another `Octonion`.
///
/// `self = self / other` (right division)
///
/// # Arguments
/// * `self` - The left-hand side `Octonion` to be modified.
/// * `other` - The right-hand side `Octonion` to divide by.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
/// use deep_causality_num::{One, Zero};
///
/// let mut o = Octonion::one(); // 1
/// let e1 = Octonion::new(0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
/// let neg_e1 = -e1;
/// o /= e1; // o becomes 1 / e1 = -e1
/// assert_eq!(o, neg_e1);
/// ```
impl<F: RealField> DivAssign for Octonion<F> {
    fn div_assign(&mut self, other: Self) {
        *self = *self / other;
    }
}

/// Implements scalar division for an `Octonion` by a scalar of type `F`.
///
/// Each component of the octonion is divided by the scalar value.
/// `o / scalar = (s / scalar, e₁ / scalar, ..., e₇ / scalar)`
///
/// # Arguments
/// * `self` - The `Octonion` to be divided.
/// * `scalar` - The scalar value of type `F`.
///
/// # Returns
/// A new `Octonion` representing the quotient of `self` divided by `scalar`.
/// If `scalar` is zero, the result will have infinite or NaN components.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let o = Octonion::new(2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0);
/// let scalar = 2.0;
/// let quot = o / scalar;
/// assert_eq!(quot.s, 1.0);
/// assert_eq!(quot.e1, 2.0);
/// // ... and so on for other components
/// ```
impl<F: RealField> Div<F> for Octonion<F> {
    type Output = Self;
    fn div(self, scalar: F) -> Self {
        let inv_scalar = F::one() / scalar;
        self * inv_scalar
    }
}

/// Implements scalar division assignment (`/=`) for an `Octonion` by a scalar of type `F`.
///
/// Each component of `self` is divided by the `scalar` value.
/// `self = self / scalar`
///
/// # Arguments
/// * `self` - The `Octonion` to be modified.
/// * `scalar` - The scalar value of type `F`.
///
/// # Examples
/// ```
/// use deep_causality_num::Octonion;
///
/// let mut o = Octonion::new(2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0);
/// let scalar = 2.0;
/// o /= scalar;
/// assert_eq!(o.s, 1.0);
/// assert_eq!(o.e1, 2.0);
/// ```
impl<F: RealField> DivAssign<F> for Octonion<F> {
    fn div_assign(&mut self, scalar: F) {
        self.s /= scalar;
        self.e1 /= scalar;
        self.e2 /= scalar;
        self.e3 /= scalar;
        self.e4 /= scalar;
        self.e5 /= scalar;
        self.e6 /= scalar;
        self.e7 /= scalar;
    }
}
