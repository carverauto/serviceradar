/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Integer traits for abstracting over primitive integer types.
//!
//! This module provides three traits:
//! - [`Integer`]: Common operations for all primitive integers
//! - [`SignedInt`]: Operations specific to signed integers
//! - [`UnsignedInt`]: Operations specific to unsigned integers

mod integer_impl;
mod signed;
mod signed_impl;
mod unsigned;
mod unsigned_impl;

pub use signed::SignedInt;
pub use unsigned::UnsignedInt;

use crate::Ring;
use core::ops::{BitAnd, BitOr, BitXor, Not, Shl, Shr};

/// A trait for primitive integer types.
///
/// This trait abstracts over both signed and unsigned integers, providing
/// common operations and constants. It extends `Ring` from the algebraic
/// hierarchy, reflecting that integers form a ring under addition and
/// multiplication.
///
/// # Mathematical Background
///
/// The integers $\mathbb{Z}$ form a **Euclidean Domain**:
/// - A commutative ring with identity
/// - Division with remainder is well-defined: $a = bq + r$ where $0 \le r < |b|$
/// - This enables the Euclidean algorithm for GCD
///
/// Fixed-width integers in computers are technically $\mathbb{Z}/2^n\mathbb{Z}$
/// (integers modulo $2^n$), but overflow behavior varies by build configuration.
pub trait Integer:
    Ring
    + Ord
    + Copy
    + Sized
    + BitAnd<Output = Self>
    + BitOr<Output = Self>
    + BitXor<Output = Self>
    + Not<Output = Self>
    + Shl<u32, Output = Self>
    + Shr<u32, Output = Self>
{
    /// The minimum value representable by this type.
    const MIN: Self;

    /// The maximum value representable by this type.
    const MAX: Self;

    /// The size of this type in bits.
    const BITS: u32;

    /// Returns the number of ones in the binary representation.
    fn count_ones(self) -> u32;

    /// Returns the number of zeros in the binary representation.
    fn count_zeros(self) -> u32;

    /// Returns the number of leading zeros in the binary representation.
    fn leading_zeros(self) -> u32;

    /// Returns the number of trailing zeros in the binary representation.
    fn trailing_zeros(self) -> u32;

    /// Reverses the byte order of the integer.
    fn swap_bytes(self) -> Self;

    /// Converts from big-endian to native byte order.
    fn from_be(x: Self) -> Self;

    /// Converts from little-endian to native byte order.
    fn from_le(x: Self) -> Self;

    /// Converts to big-endian byte order.
    fn to_be(self) -> Self;

    /// Converts to little-endian byte order.
    fn to_le(self) -> Self;

    /// Checked addition. Returns `None` on overflow.
    fn checked_add(self, rhs: Self) -> Option<Self>;

    /// Checked subtraction. Returns `None` on underflow.
    fn checked_sub(self, rhs: Self) -> Option<Self>;

    /// Checked multiplication. Returns `None` on overflow.
    fn checked_mul(self, rhs: Self) -> Option<Self>;

    /// Checked division. Returns `None` if `rhs == 0`.
    fn checked_div(self, rhs: Self) -> Option<Self>;

    /// Checked remainder. Returns `None` if `rhs == 0`.
    fn checked_rem(self, rhs: Self) -> Option<Self>;

    /// Saturating addition. Clamps at `MAX` or `MIN`.
    fn saturating_add(self, rhs: Self) -> Self;

    /// Saturating subtraction. Clamps at `MAX` or `MIN`.
    fn saturating_sub(self, rhs: Self) -> Self;

    /// Saturating multiplication. Clamps at `MAX` or `MIN`.
    fn saturating_mul(self, rhs: Self) -> Self;

    /// Wrapping addition. Wraps around on overflow.
    fn wrapping_add(self, rhs: Self) -> Self;

    /// Wrapping subtraction. Wraps around on underflow.
    fn wrapping_sub(self, rhs: Self) -> Self;

    /// Wrapping multiplication. Wraps around on overflow.
    fn wrapping_mul(self, rhs: Self) -> Self;

    /// Raises self to the power `exp`, using exponentiation by squaring.
    fn pow(self, exp: u32) -> Self;

    /// Calculates the quotient of Euclidean division.
    fn div_euclid(self, rhs: Self) -> Self;

    /// Calculates the remainder of Euclidean division.
    ///
    /// The result satisfies `0 <= r < |rhs|` for all inputs.
    fn rem_euclid(self, rhs: Self) -> Self;
}
