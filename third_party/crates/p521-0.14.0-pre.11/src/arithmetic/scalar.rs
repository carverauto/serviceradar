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
#[allow(
    clippy::identity_op,
    clippy::needless_lifetimes,
    clippy::unnecessary_cast,
    clippy::too_many_arguments
)]
#[allow(dead_code)] // TODO(tarcieri): remove this when we can use `const _` to silence warnings
mod scalar_impl;

use self::scalar_impl::*;
use crate::{FieldBytes, NistP521, ORDER_HEX, U576};
use core::{
    cmp::Ordering,
    fmt::{self, Debug},
    iter::{Product, Sum},
    ops::{Add, AddAssign, Mul, MulAssign, Neg, SubAssign},
};
use elliptic_curve::{
    Curve as _, Error, FieldBytesEncoding, Result,
    bigint::{self, Integer, NonZero},
    ff::{self, Field, PrimeField},
    ops::{Invert, Reduce, ReduceNonZero},
    rand_core::TryRngCore,
    scalar::{FromUintUnchecked, IsHigh},
    subtle::{
        Choice, ConditionallySelectable, ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess,
        CtOption,
    },
    zeroize::DefaultIsZeroes,
};

#[cfg(target_pointer_width = "32")]
use super::util::{u32x18_to_u64x9, u64x9_to_u32x18};

#[cfg(feature = "serde")]
use {
    elliptic_curve::ScalarValue,
    serdect::serde::{Deserialize, Serialize, de, ser},
};

#[cfg(doc)]
use core::ops::Sub;

primefield::monty_field_params!(
    name: ScalarParams,
    modulus: ORDER_HEX,
    uint: U576,
    byte_order: primefield::ByteOrder::BigEndian,
    multiplicative_generator: 3,
    fe_name: "Scalar",
    doc: "P-521 scalar modulus"
);

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
// TODO(tarcieri): `primefield::MontyFieldElement` as the interior type
#[derive(Clone, Copy)]
pub struct Scalar(fiat_p521_scalar_montgomery_domain_field_element);

impl Scalar {
    /// Zero element.
    pub const ZERO: Self = Self::from_u64(0);

    /// Multiplicative identity.
    pub const ONE: Self = Self::from_u64(1);

    /// Create a [`Scalar`] from a canonical big-endian representation.
    pub fn from_bytes(repr: &FieldBytes) -> CtOption<Self> {
        Self::from_uint(FieldBytesEncoding::<NistP521>::decode_field_bytes(repr))
    }

    /// Decode [`Scalar`] from a big endian byte slice.
    pub fn from_slice(slice: &[u8]) -> Result<Self> {
        let field_bytes = FieldBytes::try_from(slice).map_err(|_| Error)?;
        Self::from_bytes(&field_bytes).into_option().ok_or(Error)
    }

    /// Decode [`Scalar`] from [`U576`] converting it into Montgomery form:
    ///
    /// `w * R^2 * R^-1 mod p = wR mod p`
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
    pub(crate) const fn from_hex_unchecked(hex: &str) -> Self {
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
        let mut out = fiat_p521_scalar_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_to_montgomery(
            &mut out,
            &fiat_p521_scalar_non_montgomery_domain_field_element(u32x18_to_u64x9(w.as_words())),
        );
        Self(out)
    }

    /// Decode [`Scalar`] from [`U576`] converting it into Montgomery form.
    ///
    /// Does *not* perform a check that the field element does not overflow the order.
    ///
    /// Used incorrectly this can lead to invalid results!
    #[cfg(target_pointer_width = "64")]
    pub(crate) const fn from_uint_unchecked(w: U576) -> Self {
        let mut out = fiat_p521_scalar_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_to_montgomery(
            &mut out,
            &fiat_p521_scalar_non_montgomery_domain_field_element(*w.as_words()),
        );
        Self(out)
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
        let mut out = fiat_p521_scalar_non_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_from_montgomery(&mut out, &self.0);
        U576::from_words(u64x9_to_u32x18(&out.0))
    }

    /// Translate [`Scalar`] out of the Montgomery domain, returning a [`U576`]
    /// in canonical form.
    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub const fn to_canonical(self) -> U576 {
        let mut out = fiat_p521_scalar_non_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_from_montgomery(&mut out, &self.0);
        U576::from_words(out.0)
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
    #[inline]
    pub const fn add(&self, rhs: &Self) -> Self {
        let mut out = fiat_p521_scalar_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_add(&mut out, &self.0, &rhs.0);
        Self(out)
    }

    /// Double element (add it to itself).
    #[inline]
    #[must_use]
    pub const fn double(&self) -> Self {
        self.add(self)
    }

    /// Subtract elements.
    #[inline]
    pub const fn sub(&self, rhs: &Self) -> Self {
        let mut out = fiat_p521_scalar_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_sub(&mut out, &self.0, &rhs.0);
        Self(out)
    }

    /// Negate element.
    #[inline]
    pub const fn neg(&self) -> Self {
        let mut out = fiat_p521_scalar_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_opp(&mut out, &self.0);
        Self(out)
    }

    /// Multiply elements.
    #[inline]
    pub const fn multiply(&self, rhs: &Self) -> Self {
        let mut out = fiat_p521_scalar_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_mul(&mut out, &self.0, &rhs.0);
        Self(out)
    }

    /// Compute [`Scalar`] inversion: `1 / self`.
    pub fn invert(&self) -> CtOption<Self> {
        CtOption::new(self.invert_unchecked(), !self.is_zero())
    }

    /// Compute [`Scalar`] inversion: `1 / self`.
    ///
    /// Does not check that self is non-zero.
    const fn invert_unchecked(&self) -> Self {
        let words = primefield::fiat_bernstein_yang_invert!(
            &self.0,
            Self::ONE.0,
            521,
            9,
            u64,
            fiat_p521_scalar_non_montgomery_domain_field_element,
            fiat_p521_scalar_montgomery_domain_field_element,
            fiat_p521_scalar_from_montgomery,
            fiat_p521_scalar_mul,
            fiat_p521_scalar_opp,
            fiat_p521_scalar_divstep_precomp,
            fiat_p521_scalar_divstep,
            fiat_p521_scalar_msat,
            fiat_p521_scalar_selectznz
        );

        Self(fiat_p521_scalar_montgomery_domain_field_element(words))
    }

    /// Compute modular square.
    #[inline]
    #[must_use]
    pub const fn square(&self) -> Self {
        let mut out = fiat_p521_scalar_montgomery_domain_field_element([0; 9]);
        fiat_p521_scalar_square(&mut out, &self.0);
        Self(out)
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

    /// Borrow the inner limbs of this scalar.
    pub(crate) const fn as_limbs(&self) -> &[u64; 9] {
        &self.0.0
    }

    /// Extract the inner limbs of this scalar.
    pub(crate) const fn into_limbs(self) -> [u64; 9] {
        self.0.0
    }
}

impl AsRef<fiat_p521_scalar_montgomery_domain_field_element> for Scalar {
    fn as_ref(&self) -> &fiat_p521_scalar_montgomery_domain_field_element {
        &self.0
    }
}

impl Debug for Scalar {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Scalar({:X})", self.to_canonical())
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
        self.as_limbs().ct_eq(rhs.as_limbs()).into()
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
        let mut ret = Self::ZERO.into_limbs();
        let a = a.as_limbs();
        let b = b.as_limbs();

        for i in 0..ret.len() {
            ret[i] = u64::conditional_select(&a[i], &b[i], choice);
        }

        Self(fiat_p521_scalar_montgomery_domain_field_element(ret))
    }
}

impl ConstantTimeEq for Scalar {
    fn ct_eq(&self, other: &Self) -> Choice {
        self.as_limbs().ct_eq(other.as_limbs())
    }
}

impl DefaultIsZeroes for Scalar {}

impl Field for Scalar {
    const ZERO: Self = Self::ZERO;
    const ONE: Self = Self::ONE;

    fn try_from_rng<R: TryRngCore + ?Sized>(rng: &mut R) -> core::result::Result<Self, R::Error> {
        // NOTE: can't use ScalarValue::random due to CryptoRng bound
        let mut bytes = <FieldBytes>::default();

        loop {
            rng.try_fill_bytes(&mut bytes)?;
            if let Some(fe) = Self::from_bytes(&bytes).into() {
                return Ok(fe);
            }
        }
    }

    fn is_zero(&self) -> Choice {
        Self::ZERO.ct_eq(self)
    }

    fn square(&self) -> Self {
        self.square()
    }

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

primefield::field_op!(Scalar, Add, add, add);
primefield::field_op!(Scalar, Sub, sub, sub);
primefield::field_op!(Scalar, Mul, mul, multiply);
elliptic_curve::scalar_impls!(NistP521, Scalar);

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
        iter.reduce(Add::add).unwrap_or(Self::ZERO)
    }
}

impl<'a> Sum<&'a Scalar> for Scalar {
    fn sum<I: Iterator<Item = &'a Scalar>>(iter: I) -> Self {
        iter.copied().sum()
    }
}

impl Product for Scalar {
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.reduce(Mul::mul).unwrap_or(Self::ONE)
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
        const MODULUS_SHR1: U576 = NistP521::ORDER.as_ref().shr_vartime(1);
        self.to_canonical().ct_gt(&MODULUS_SHR1)
    }
}

impl Ord for Scalar {
    fn cmp(&self, other: &Self) -> Ordering {
        self.to_canonical().cmp(&other.to_canonical())
    }
}

impl PartialOrd for Scalar {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

// TODO(tarcieri): use `primefield` to derive `PrimeField` impl
impl PrimeField for Scalar {
    type Repr = FieldBytes;

    const MODULUS: &'static str = ORDER_HEX;
    const CAPACITY: u32 = 520;
    const NUM_BITS: u32 = 521;
    const TWO_INV: Self = Self::from_u64(2).invert_unchecked();
    const MULTIPLICATIVE_GENERATOR: Self = Self::from_u64(3);
    const S: u32 = 3;
    const ROOT_OF_UNITY: Self = Self::from_hex_unchecked(
        "000000000000009a0a650d44b28c17f3d708ad2fa8c4fbc7e6000d7c12dafa92fcc5673a3055276d535f79ff391dcdbcd998b7836647d3a72472b3da861ac810a7f9c7b7b63e2205",
    );
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

impl Reduce<U576> for Scalar {
    fn reduce(w: &U576) -> Self {
        let (r, underflow) = w.borrowing_sub(&NistP521::ORDER, bigint::Limb::ZERO);
        let underflow = Choice::from((underflow.0 >> (bigint::Limb::BITS - 1)) as u8);
        Self::from_uint_unchecked(U576::conditional_select(w, &r, !underflow))
    }
}
impl Reduce<FieldBytes> for Scalar {
    #[inline]
    fn reduce(bytes: &FieldBytes) -> Self {
        let w = <U576 as FieldBytesEncoding<NistP521>>::decode_field_bytes(bytes);
        Self::reduce(&w)
    }
}

impl ReduceNonZero<U576> for Scalar {
    fn reduce_nonzero(w: &U576) -> Self {
        const ORDER_MINUS_ONE: U576 = NistP521::ORDER.as_ref().wrapping_sub(&U576::ONE);
        let r = w.rem(&NonZero::new(ORDER_MINUS_ONE).unwrap());
        Self::from_uint_unchecked(r.wrapping_add(&U576::ONE))
    }
}

impl ReduceNonZero<FieldBytes> for Scalar {
    #[inline]
    fn reduce_nonzero(bytes: &FieldBytes) -> Self {
        let w = <U576 as FieldBytesEncoding<NistP521>>::decode_field_bytes(bytes);
        Self::reduce_nonzero(&w)
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
        ScalarValue::from(self).serialize(serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for Scalar {
    fn deserialize<D>(deserializer: D) -> core::result::Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        Ok(ScalarValue::deserialize(deserializer)?.into())
    }
}

#[cfg(test)]
mod tests {
    use crate::{FieldBytes, NistP521, NonZeroScalar};

    use super::{Scalar, U576};
    use elliptic_curve::{
        Curve,
        array::Array,
        ops::{BatchInvert, ReduceNonZero},
    };
    use proptest::{prelude::any, prop_compose, proptest};

    primefield::test_primefield_constants!(Scalar, U576);
    primefield::test_field_identity!(Scalar);
    primefield::test_field_invert!(Scalar);
    //primefield::test_field_sqrt!(Scalar); // TODO(tarcieri): impl this

    #[test]
    fn reduce_nonzero() {
        assert_eq!(
            U576::from(Scalar::reduce_nonzero(&Array::default())),
            U576::ONE,
        );
        assert_eq!(
            U576::from(Scalar::reduce_nonzero(&U576::ONE)),
            U576::from_u8(2),
        );
        assert_eq!(
            U576::from(Scalar::reduce_nonzero(&U576::from_u8(2))),
            U576::from_u8(3),
        );

        assert_eq!(
            U576::from(Scalar::reduce_nonzero(NistP521::ORDER.as_ref())),
            U576::from_u8(2),
        );
        assert_eq!(
            U576::from(Scalar::reduce_nonzero(
                &NistP521::ORDER.wrapping_sub(&U576::from_u8(1))
            )),
            U576::ONE,
        );
        assert_eq!(
            U576::from(Scalar::reduce_nonzero(
                &NistP521::ORDER.wrapping_sub(&U576::from_u8(2))
            )),
            NistP521::ORDER.wrapping_sub(&U576::ONE),
        );
        assert_eq!(
            U576::from(Scalar::reduce_nonzero(
                &NistP521::ORDER.wrapping_sub(&U576::from_u8(3))
            )),
            NistP521::ORDER.wrapping_sub(&U576::from_u8(2)),
        );

        assert_eq!(
            U576::from(Scalar::reduce_nonzero(
                &NistP521::ORDER.wrapping_add(&U576::ONE)
            )),
            U576::from_u8(3),
        );
        assert_eq!(
            U576::from(Scalar::reduce_nonzero(
                &NistP521::ORDER.wrapping_add(&U576::from_u8(2))
            )),
            U576::from_u8(4),
        );

        assert_eq!(
            U576::from(Scalar::reduce_nonzero(
                &NistP521::ORDER.wrapping_mul(&U576::from_u8(3))
            )),
            U576::from_u8(4),
        );
    }

    prop_compose! {
        fn non_zero_scalar()(bytes in any::<[u8; 66]>()) -> NonZeroScalar {
            NonZeroScalar::reduce_nonzero(&FieldBytes::from(bytes))
        }
    }

    // TODO: move to `primefield::test_field_invert`.
    proptest! {
        #[test]
        fn batch_invert(
            a in non_zero_scalar(),
            b in non_zero_scalar(),
            c in non_zero_scalar(),
            d in non_zero_scalar(),
            e in non_zero_scalar(),
        ) {
            let scalars: [Scalar; 5] = [*a, *b, *c, *d, *e];

            let inverted_scalars = Scalar::batch_invert(scalars).unwrap();

            for (scalar, inverted_scalar) in scalars.into_iter().zip(inverted_scalars) {
                assert_eq!(inverted_scalar, scalar.invert().unwrap());
            }
        }
    }
}
