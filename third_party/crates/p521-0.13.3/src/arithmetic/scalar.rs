//! secp521r1 scalar field elements.
//!
//! Arithmetic implementations have been synthesized using fiat-crypto.
//!
//! # License
//!
//! Copyright (c) 2015-2020 the fiat-crypto authors
//!
//! fiat-crypto is distributed under the terms of the MIT License, the
//! Apache License (Version 2.0), and the BSD 1-Clause License;
//! users may pick which license to apply.

// TODO(tarcieri): 32-bit backend?
#[path = "scalar/p521_scalar_64.rs"]
mod scalar_impl;

use self::scalar_impl::*;
use crate::{FieldBytes, NistP521, SecretKey, U576};
use core::{
    iter::{Product, Sum},
    ops::{AddAssign, MulAssign, Neg, Shr, ShrAssign, SubAssign},
};
use elliptic_curve::{
    bigint::{self, Integer},
    ff::{self, Field, PrimeField},
    generic_array::GenericArray,
    ops::{Invert, Reduce},
    rand_core::RngCore,
    scalar::{FromUintUnchecked, IsHigh},
    subtle::{
        Choice, ConditionallySelectable, ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess,
        CtOption,
    },
    zeroize::DefaultIsZeroes,
    Curve as _, Error, FieldBytesEncoding, Result, ScalarPrimitive,
};
use primeorder::{impl_bernstein_yang_invert, impl_field_op};

#[cfg(feature = "bits")]
use {crate::ScalarBits, elliptic_curve::group::ff::PrimeFieldBits};

#[cfg(feature = "serde")]
use serdect::serde::{de, ser, Deserialize, Serialize};

#[cfg(doc)]
use core::ops::{Add, Mul, Sub};

#[cfg(target_pointer_width = "32")]
use super::util::{u32x18_to_u64x9, u64x9_to_u32x18};

/// Scalars are elements in the finite field modulo `n`.
///
/// # Trait impls
///
/// Much of the important functionality of scalars is provided by traits from
/// the [`ff`](https://docs.rs/ff/) crate, which is re-exported as
/// `p521::elliptic_curve::ff`:
///
/// - [`Field`](https://docs.rs/ff/latest/ff/trait.Field.html) -
///   represents elements of finite fields and provides:
///   - [`Field::random`](https://docs.rs/ff/latest/ff/trait.Field.html#tymethod.random) -
///     generate a random scalar
///   - `double`, `square`, and `invert` operations
///   - Bounds for [`Add`], [`Sub`], [`Mul`], and [`Neg`] (as well as `*Assign` equivalents)
///   - Bounds for [`ConditionallySelectable`] from the `subtle` crate
/// - [`PrimeField`](https://docs.rs/ff/latest/ff/trait.PrimeField.html) -
///   represents elements of prime fields and provides:
///   - `from_repr`/`to_repr` for converting field elements from/to big integers.
///   - `multiplicative_generator` and `root_of_unity` constants.
/// - [`PrimeFieldBits`](https://docs.rs/ff/latest/ff/trait.PrimeFieldBits.html) -
///   operations over field elements represented as bits (requires `bits` feature)
///
/// Please see the documentation for the relevant traits for more information.
#[derive(Clone, Copy, Debug, PartialOrd, Ord)]
pub struct Scalar(fiat_p521_scalar_montgomery_domain_field_element);

impl Scalar {
    /// Zero element.
    pub const ZERO: Self = Self::from_u64(0);

    /// Multiplicative identity.
    pub const ONE: Self = Self::from_u64(1);

    /// Number of bytes in the serialized representation.
    const BYTES: usize = 66;

    /// Create a [`Scalar`] from a canonical big-endian representation.
    pub fn from_bytes(repr: &FieldBytes) -> CtOption<Self> {
        Self::from_uint(FieldBytesEncoding::<NistP521>::decode_field_bytes(repr))
    }

    /// Decode [`Scalar`] from a big endian byte slice.
    pub fn from_slice(slice: &[u8]) -> Result<Self> {
        if slice.len() != Self::BYTES {
            return Err(Error);
        }

        Option::from(Self::from_bytes(GenericArray::from_slice(slice))).ok_or(Error)
    }

    /// Decode [`Scalar`] from [`U576`] converting it into Montgomery form:
    ///
    /// ```text
    /// w * R^2 * R^-1 mod p = wR mod p
    /// ```
    pub fn from_uint(uint: U576) -> CtOption<Self> {
        let is_some = uint.ct_lt(&NistP521::ORDER);
        CtOption::new(Self::from_uint_unchecked(uint), is_some)
    }

    /// Parse a [`Scalar`] from big endian hex-encoded bytes.
    ///
    /// Does *not* perform a check that the field element does not overflow the order.
    ///
    /// This method is primarily intended for defining internal constants.
    #[allow(dead_code)]
    pub(crate) const fn from_hex(hex: &str) -> Self {
        Self::from_uint_unchecked(U576::from_be_hex(hex))
    }

    /// Convert a `u64` into a [`Scalar`].
    pub const fn from_u64(w: u64) -> Self {
        Self::from_uint_unchecked(U576::from_u64(w))
    }

    /// Decode [`Scalar`] from [`U576`] converting it into Montgomery form.
    ///
    /// Does *not* perform a check that the field element does not overflow the order.
    ///
    /// Used incorrectly this can lead to invalid results!
    #[cfg(target_pointer_width = "32")]
    pub(crate) const fn from_uint_unchecked(w: U576) -> Self {
        Self(fiat_p521_scalar_to_montgomery(&u32x18_to_u64x9(
            w.as_words(),
        )))
    }

    /// Decode [`Scalar`] from [`U576`] converting it into Montgomery form.
    ///
    /// Does *not* perform a check that the field element does not overflow the order.
    ///
    /// Used incorrectly this can lead to invalid results!
    #[cfg(target_pointer_width = "64")]
    pub(crate) const fn from_uint_unchecked(w: U576) -> Self {
        Self(fiat_p521_scalar_to_montgomery(w.as_words()))
    }

    /// Returns the big-endian encoding of this [`Scalar`].
    pub fn to_bytes(self) -> FieldBytes {
        FieldBytesEncoding::<NistP521>::encode_field_bytes(&self.to_canonical())
    }

    /// Translate [`Scalar`] out of the Montgomery domain, returning a [`U576`]
    /// in canonical form.
    #[inline]
    #[cfg(target_pointer_width = "32")]
    pub const fn to_canonical(self) -> U576 {
        U576::from_words(u64x9_to_u32x18(&fiat_p521_scalar_from_montgomery(&self.0)))
    }

    /// Translate [`Scalar`] out of the Montgomery domain, returning a [`U576`]
    /// in canonical form.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub const fn to_canonical(self) -> U576 {
        U576::from_words(fiat_p521_scalar_from_montgomery(&self.0))
    }

    /// Determine if this [`Scalar`] is odd in the SEC1 sense: `self mod 2 == 1`.
    ///
    /// # Returns
    ///
    /// If odd, return `Choice(1)`.  Otherwise, return `Choice(0)`.
    pub fn is_odd(&self) -> Choice {
        self.to_canonical().is_odd()
    }

    /// Determine if this [`Scalar`] is even in the SEC1 sense: `self mod 2 == 0`.
    ///
    /// # Returns
    ///
    /// If even, return `Choice(1)`.  Otherwise, return `Choice(0)`.
    pub fn is_even(&self) -> Choice {
        !self.is_odd()
    }

    /// Determine if this [`Scalar`] is zero.
    ///
    /// # Returns
    ///
    /// If zero, return `Choice(1)`.  Otherwise, return `Choice(0)`.
    pub fn is_zero(&self) -> Choice {
        self.ct_eq(&Self::ZERO)
    }

    /// Add elements.
    pub const fn add(&self, rhs: &Self) -> Self {
        Self(fiat_p521_scalar_add(&self.0, &rhs.0))
    }

    /// Double element (add it to itself).
    #[must_use]
    pub const fn double(&self) -> Self {
        self.add(self)
    }

    /// Subtract elements.
    pub const fn sub(&self, rhs: &Self) -> Self {
        Self(fiat_p521_scalar_sub(&self.0, &rhs.0))
    }

    /// Negate element.
    pub const fn neg(&self) -> Self {
        Self(fiat_p521_scalar_opp(&self.0))
    }

    /// Multiply elements.
    pub const fn multiply(&self, rhs: &Self) -> Self {
        Self(fiat_p521_scalar_mul(&self.0, &rhs.0))
    }

    /// Compute [`Scalar`] inversion: `1 / self`.
    pub fn invert(&self) -> CtOption<Self> {
        CtOption::new(self.invert_unchecked(), !self.is_zero())
    }

    /// Compute [`Scalar`] inversion: `1 / self`.
    ///
    /// Does not check that self is non-zero.
    const fn invert_unchecked(&self) -> Self {
        let words = impl_bernstein_yang_invert!(
            &self.0,
            Self::ONE.0,
            521,
            9,
            u64,
            fiat_p521_scalar_from_montgomery,
            fiat_p521_scalar_mul,
            fiat_p521_scalar_opp,
            fiat_p521_scalar_divstep_precomp,
            fiat_p521_scalar_divstep,
            fiat_p521_scalar_msat,
            fiat_p521_scalar_selectznz,
        );

        Self(words)
    }

    /// Compute modular square.
    #[must_use]
    pub const fn square(&self) -> Self {
        Self(fiat_p521_scalar_square(&self.0))
    }

    /// Compute modular square root.
    pub fn sqrt(&self) -> CtOption<Self> {
        todo!("`sqrt` not yet implemented")
    }

    /// Returns `self^exp`, where `exp` is a little-endian integer exponent.
    ///
    /// **This operation is variable time with respect to the exponent.**
    ///
    /// If the exponent is fixed, this operation is effectively constant time.
    pub const fn pow_vartime(&self, exp: &[u64]) -> Self {
        let mut res = Self::ONE;
        let mut i = exp.len();

        while i > 0 {
            i -= 1;

            let mut j = 64;
            while j > 0 {
                j -= 1;
                res = res.square();

                if ((exp[i] >> j) & 1) == 1 {
                    res = res.multiply(self);
                }
            }
        }

        res
    }

    /// Right shifts the scalar.
    ///
    /// Note: not constant-time with respect to the `shift` parameter.
    #[cfg(target_pointer_width = "32")]
    pub const fn shr_vartime(&self, shift: usize) -> Scalar {
        Self(u32x18_to_u64x9(
            &U576::from_words(u64x9_to_u32x18(&self.0))
                .shr_vartime(shift)
                .to_words(),
        ))
    }

    /// Right shifts the scalar.
    ///
    /// Note: not constant-time with respect to the `shift` parameter.
    #[cfg(target_pointer_width = "64")]
    pub const fn shr_vartime(&self, shift: usize) -> Scalar {
        Self(U576::from_words(self.0).shr_vartime(shift).to_words())
    }
}

impl AsRef<fiat_p521_scalar_montgomery_domain_field_element> for Scalar {
    fn as_ref(&self) -> &fiat_p521_scalar_montgomery_domain_field_element {
        &self.0
    }
}

impl Default for Scalar {
    fn default() -> Self {
        Self::ZERO
    }
}

impl Eq for Scalar {}
impl PartialEq for Scalar {
    fn eq(&self, rhs: &Self) -> bool {
        self.0.ct_eq(&(rhs.0)).into()
    }
}

impl From<u32> for Scalar {
    fn from(n: u32) -> Scalar {
        Self::from_uint_unchecked(U576::from(n))
    }
}

impl From<u64> for Scalar {
    fn from(n: u64) -> Scalar {
        Self::from_uint_unchecked(U576::from(n))
    }
}

impl From<u128> for Scalar {
    fn from(n: u128) -> Scalar {
        Self::from_uint_unchecked(U576::from(n))
    }
}

impl ConditionallySelectable for Scalar {
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        let mut ret = Self::ZERO;

        for i in 0..ret.0.len() {
            ret.0[i] = u64::conditional_select(&a.0[i], &b.0[i], choice);
        }

        ret
    }
}

impl ConstantTimeEq for Scalar {
    fn ct_eq(&self, other: &Self) -> Choice {
        self.0.ct_eq(&other.0)
    }
}

impl DefaultIsZeroes for Scalar {}

impl Field for Scalar {
    const ZERO: Self = Self::ZERO;
    const ONE: Self = Self::ONE;

    fn random(mut rng: impl RngCore) -> Self {
        // NOTE: can't use ScalarPrimitive::random due to CryptoRng bound
        let mut bytes = <FieldBytes>::default();

        loop {
            rng.fill_bytes(&mut bytes);
            if let Some(fe) = Self::from_bytes(&bytes).into() {
                return fe;
            }
        }
    }

    fn is_zero(&self) -> Choice {
        Self::ZERO.ct_eq(self)
    }

    #[must_use]
    fn square(&self) -> Self {
        self.square()
    }

    #[must_use]
    fn double(&self) -> Self {
        self.double()
    }

    fn invert(&self) -> CtOption<Self> {
        self.invert()
    }

    fn sqrt(&self) -> CtOption<Self> {
        self.sqrt()
    }

    fn sqrt_ratio(num: &Self, div: &Self) -> (Choice, Self) {
        ff::helpers::sqrt_ratio_generic(num, div)
    }
}

impl_field_op!(Scalar, Add, add, fiat_p521_scalar_add);
impl_field_op!(Scalar, Sub, sub, fiat_p521_scalar_sub);
impl_field_op!(Scalar, Mul, mul, fiat_p521_scalar_mul);

impl AddAssign<Scalar> for Scalar {
    #[inline]
    fn add_assign(&mut self, other: Scalar) {
        *self = *self + other;
    }
}

impl AddAssign<&Scalar> for Scalar {
    #[inline]
    fn add_assign(&mut self, other: &Scalar) {
        *self = *self + other;
    }
}

impl SubAssign<Scalar> for Scalar {
    #[inline]
    fn sub_assign(&mut self, other: Scalar) {
        *self = *self - other;
    }
}

impl SubAssign<&Scalar> for Scalar {
    #[inline]
    fn sub_assign(&mut self, other: &Scalar) {
        *self = *self - other;
    }
}

impl MulAssign<&Scalar> for Scalar {
    #[inline]
    fn mul_assign(&mut self, other: &Scalar) {
        *self = *self * other;
    }
}

impl MulAssign for Scalar {
    #[inline]
    fn mul_assign(&mut self, other: Scalar) {
        *self = *self * other;
    }
}

impl Neg for Scalar {
    type Output = Scalar;

    #[inline]
    fn neg(self) -> Scalar {
        Self::neg(&self)
    }
}

impl Sum for Scalar {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.reduce(core::ops::Add::add).unwrap_or(Self::ZERO)
    }
}

impl<'a> Sum<&'a Scalar> for Scalar {
    fn sum<I: Iterator<Item = &'a Scalar>>(iter: I) -> Self {
        iter.copied().sum()
    }
}

impl Product for Scalar {
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.reduce(core::ops::Mul::mul).unwrap_or(Self::ONE)
    }
}

impl<'a> Product<&'a Scalar> for Scalar {
    fn product<I: Iterator<Item = &'a Self>>(iter: I) -> Self {
        iter.copied().product()
    }
}

impl AsRef<Scalar> for Scalar {
    fn as_ref(&self) -> &Scalar {
        self
    }
}

impl FromUintUnchecked for Scalar {
    type Uint = U576;

    fn from_uint_unchecked(uint: Self::Uint) -> Self {
        Self::from_uint_unchecked(uint)
    }
}

impl Invert for Scalar {
    type Output = CtOption<Self>;

    fn invert(&self) -> CtOption<Self> {
        self.invert()
    }
}

impl IsHigh for Scalar {
    fn is_high(&self) -> Choice {
        const MODULUS_SHR1: U576 = NistP521::ORDER.shr_vartime(1);
        self.to_canonical().ct_gt(&MODULUS_SHR1)
    }
}

impl Shr<usize> for Scalar {
    type Output = Self;

    fn shr(self, rhs: usize) -> Self::Output {
        self.shr_vartime(rhs)
    }
}

impl Shr<usize> for &Scalar {
    type Output = Scalar;

    fn shr(self, rhs: usize) -> Self::Output {
        self.shr_vartime(rhs)
    }
}

impl ShrAssign<usize> for Scalar {
    fn shr_assign(&mut self, rhs: usize) {
        *self = *self >> rhs;
    }
}

impl PrimeField for Scalar {
    type Repr = FieldBytes;

    const MODULUS: &'static str = "01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409";
    const CAPACITY: u32 = 520;
    const NUM_BITS: u32 = 521;
    const TWO_INV: Self = Self::from_u64(2).invert_unchecked();
    const MULTIPLICATIVE_GENERATOR: Self = Self::from_u64(3);
    const S: u32 = 3;
    const ROOT_OF_UNITY: Self = Self::from_hex("000000000000009a0a650d44b28c17f3d708ad2fa8c4fbc7e6000d7c12dafa92fcc5673a3055276d535f79ff391dcdbcd998b7836647d3a72472b3da861ac810a7f9c7b7b63e2205");
    const ROOT_OF_UNITY_INV: Self = Self::ROOT_OF_UNITY.invert_unchecked();
    const DELTA: Self = Self::from_u64(6561);

    #[inline]
    fn from_repr(bytes: FieldBytes) -> CtOption<Self> {
        Self::from_bytes(&bytes)
    }

    #[inline]
    fn to_repr(&self) -> FieldBytes {
        self.to_bytes()
    }

    #[inline]
    fn is_odd(&self) -> Choice {
        self.is_odd()
    }
}

#[cfg(feature = "bits")]
impl PrimeFieldBits for Scalar {
    type ReprBits = fiat_p521_scalar_montgomery_domain_field_element;

    fn to_le_bits(&self) -> ScalarBits {
        self.to_canonical().to_words().into()
    }

    fn char_le_bits() -> ScalarBits {
        NistP521::ORDER.to_words().into()
    }
}

impl Reduce<U576> for Scalar {
    type Bytes = FieldBytes;

    fn reduce(w: U576) -> Self {
        let (r, underflow) = w.sbb(&NistP521::ORDER, bigint::Limb::ZERO);
        let underflow = Choice::from((underflow.0 >> (bigint::Limb::BITS - 1)) as u8);
        Self::from_uint_unchecked(U576::conditional_select(&w, &r, !underflow))
    }

    #[inline]
    fn reduce_bytes(bytes: &FieldBytes) -> Self {
        let w = <U576 as FieldBytesEncoding<NistP521>>::decode_field_bytes(bytes);
        Self::reduce(w)
    }
}

impl From<ScalarPrimitive<NistP521>> for Scalar {
    fn from(w: ScalarPrimitive<NistP521>) -> Self {
        Scalar::from(&w)
    }
}

impl From<&ScalarPrimitive<NistP521>> for Scalar {
    fn from(w: &ScalarPrimitive<NistP521>) -> Scalar {
        Scalar::from_uint_unchecked(*w.as_uint())
    }
}

impl From<Scalar> for ScalarPrimitive<NistP521> {
    fn from(scalar: Scalar) -> ScalarPrimitive<NistP521> {
        ScalarPrimitive::from(&scalar)
    }
}

impl From<&Scalar> for ScalarPrimitive<NistP521> {
    fn from(scalar: &Scalar) -> ScalarPrimitive<NistP521> {
        ScalarPrimitive::new(scalar.into()).unwrap()
    }
}

impl From<Scalar> for FieldBytes {
    fn from(scalar: Scalar) -> Self {
        scalar.to_repr()
    }
}

impl From<&Scalar> for FieldBytes {
    fn from(scalar: &Scalar) -> Self {
        scalar.to_repr()
    }
}

impl From<Scalar> for U576 {
    fn from(scalar: Scalar) -> U576 {
        U576::from(&scalar)
    }
}

impl From<&Scalar> for U576 {
    fn from(scalar: &Scalar) -> U576 {
        scalar.to_canonical()
    }
}

impl From<&SecretKey> for Scalar {
    fn from(secret_key: &SecretKey) -> Scalar {
        *secret_key.to_nonzero_scalar()
    }
}

impl TryFrom<U576> for Scalar {
    type Error = Error;

    fn try_from(w: U576) -> Result<Self> {
        Option::from(Self::from_uint(w)).ok_or(Error)
    }
}

#[cfg(feature = "serde")]
impl Serialize for Scalar {
    fn serialize<S>(&self, serializer: S) -> core::result::Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        ScalarPrimitive::from(self).serialize(serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for Scalar {
    fn deserialize<D>(deserializer: D) -> core::result::Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        Ok(ScalarPrimitive::deserialize(deserializer)?.into())
    }
}

#[cfg(test)]
mod tests {
    use super::Scalar;
    use elliptic_curve::PrimeField;
    use primeorder::{impl_field_identity_tests, impl_field_invert_tests, impl_primefield_tests};

    /// t = (modulus - 1) >> S
    const T: [u64; 9] = [
        0xd76df6e3d2270c81,
        0x0776b937113388f5,
        0x6ff980291ee134ba,
        0x4a30d0f077e5f2cd,
        0xffffffffffffffff,
        0xffffffffffffffff,
        0xffffffffffffffff,
        0xffffffffffffffff,
        0x000000000000003f,
    ];

    impl_field_identity_tests!(Scalar);
    impl_field_invert_tests!(Scalar);
    impl_primefield_tests!(Scalar, T);
}
