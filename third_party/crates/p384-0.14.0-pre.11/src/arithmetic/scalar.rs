//! secp384r1 scalar field elements.
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

#[cfg(target_pointer_width = "32")]
use fiat_crypto::p384_scalar_32::*;
#[cfg(target_pointer_width = "64")]
use fiat_crypto::p384_scalar_64::*;

use crate::{FieldBytes, NistP384, ORDER_HEX, U384};
use elliptic_curve::{
    Curve as _, Error, Result,
    bigint::{ArrayEncoding, Limb},
    ff::PrimeField,
    ops::{Reduce, ReduceNonZero},
    scalar::{FromUintUnchecked, IsHigh},
    subtle::{Choice, ConditionallySelectable, ConstantTimeEq, ConstantTimeGreater, CtOption},
};

#[cfg(feature = "serde")]
use {
    elliptic_curve::ScalarValue,
    serdect::serde::{Deserialize, Serialize, de, ser},
};

#[cfg(doc)]
use core::ops::{Add, Mul, Neg, Sub};

primefield::monty_field_params!(
    name: ScalarParams,
    modulus: ORDER_HEX,
    uint: U384,
    byte_order: primefield::ByteOrder::BigEndian,
    multiplicative_generator: 2,
    fe_name: "Scalar",
    doc: "P-384 scalar modulus"
);

/// Scalars are elements in the finite field modulo `n`.
///
/// # Trait impls
///
/// Much of the important functionality of scalars is provided by traits from
/// the [`ff`](https://docs.rs/ff/) crate, which is re-exported as
/// `p384::elliptic_curve::ff`:
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
///
/// # `serde` support
///
/// When the `serde` feature of this crate is enabled, the `Serialize` and
/// `Deserialize` traits are impl'd for this type.
///
/// The serialization is a fixed-width big endian encoding. When used with
/// textual formats, the binary data is encoded as hexadecimal.
#[derive(Clone, Copy, PartialOrd, Ord)]
pub struct Scalar(primefield::MontyFieldElement<ScalarParams, { ScalarParams::LIMBS }>);

primefield::monty_field_element!(Scalar, ScalarParams, U384);

primefield::monty_field_fiat_arithmetic!(
    Scalar,
    ScalarParams,
    U384,
    fiat_p384_scalar_non_montgomery_domain_field_element,
    fiat_p384_scalar_montgomery_domain_field_element,
    fiat_p384_scalar_from_montgomery,
    fiat_p384_scalar_to_montgomery,
    fiat_p384_scalar_add,
    fiat_p384_scalar_sub,
    fiat_p384_scalar_mul,
    fiat_p384_scalar_opp,
    fiat_p384_scalar_square,
    fiat_p384_scalar_divstep_precomp,
    fiat_p384_scalar_divstep,
    fiat_p384_scalar_msat,
    fiat_p384_scalar_selectznz
);

elliptic_curve::scalar_impls!(NistP384, Scalar);

impl Scalar {
    /// Compute modular square root.
    pub fn sqrt(&self) -> CtOption<Self> {
        // p mod 4 = 3 -> compute sqrt(x) using x^((p+1)/4) =
        // x^9850501549098619803069760025035903451269934817616361666986726319906914849778315892349739077038073728388608413485661
        let t1 = *self;
        let t10 = t1.square();
        let t11 = *self * t10;
        let t101 = t10 * t11;
        let t111 = t10 * t101;
        let t1001 = t10 * t111;
        let t1011 = t10 * t1001;
        let t1101 = t10 * t1011;
        let t1111 = t10 * t1101;
        let t11110 = t1111.square();
        let t11111 = t1 * t11110;
        let t1111100 = t11111.sqn(2);
        let t11111000 = t1111100.square();
        let i14 = t11111000.square();
        let i20 = i14.sqn(5) * i14;
        let i31 = i20.sqn(10) * i20;
        let i58 = (i31.sqn(4) * t11111000).sqn(21) * i31;
        let i110 = (i58.sqn(3) * t1111100).sqn(47) * i58;
        let x194 = i110.sqn(95) * i110 * t1111;
        let i225 = ((x194.sqn(6) * t111).sqn(3) * t11).sqn(7);
        let i235 = ((t1101 * i225).sqn(6) * t1101).square() * t1;
        let i258 = ((i235.sqn(11) * t11111).sqn(2) * t1).sqn(8);
        let i269 = ((t1101 * i258).sqn(2) * t11).sqn(6) * t1011;
        let i286 = ((i269.sqn(4) * t111).sqn(6) * t11111).sqn(5);
        let i308 = ((t1011 * i286).sqn(10) * t1101).sqn(9) * t1101;
        let i323 = ((i308.sqn(4) * t1011).sqn(6) * t1001).sqn(3);
        let i340 = ((t1 * i323).sqn(7) * t1011).sqn(7) * t101;
        let i357 = ((i340.sqn(5) * t111).sqn(5) * t1111).sqn(5);
        let i369 = ((t1011 * i357).sqn(4) * t1011).sqn(5) * t111;
        let i387 = ((i369.sqn(3) * t11).sqn(7) * t11).sqn(6);
        let i397 = ((t1011 * i387).sqn(4) * t101).sqn(3) * t11;
        let i413 = ((i397.sqn(4) * t11).sqn(4) * t11).sqn(6);
        let i427 = ((t101 * i413).sqn(5) * t101).sqn(6) * t1011;
        let x = i427.sqn(3) * t101;
        CtOption::new(x, x.square().ct_eq(&t1))
    }

    /// Returns self^(2^n) mod p
    const fn sqn(&self, n: usize) -> Self {
        Self(self.0.sqn_vartime(n))
    }
}

impl AsRef<Scalar> for Scalar {
    fn as_ref(&self) -> &Scalar {
        self
    }
}

impl FromUintUnchecked for Scalar {
    type Uint = U384;

    fn from_uint_unchecked(uint: Self::Uint) -> Self {
        Self::from_uint_unchecked(uint)
    }
}

impl IsHigh for Scalar {
    fn is_high(&self) -> Choice {
        const MODULUS_SHR1: U384 = NistP384::ORDER.as_ref().shr_vartime(1);
        self.to_canonical().ct_gt(&MODULUS_SHR1)
    }
}

impl Reduce<U384> for Scalar {
    fn reduce(w: &U384) -> Self {
        let (r, underflow) = w.borrowing_sub(&NistP384::ORDER, Limb::ZERO);
        let underflow = Choice::from((underflow.0 >> (Limb::BITS - 1)) as u8);
        Self::from_uint_unchecked(U384::conditional_select(w, &r, !underflow))
    }
}

impl Reduce<FieldBytes> for Scalar {
    #[inline]
    fn reduce(bytes: &FieldBytes) -> Self {
        Self::reduce(&U384::from_be_byte_array(*bytes))
    }
}

impl ReduceNonZero<U384> for Scalar {
    fn reduce_nonzero(w: &U384) -> Self {
        const ORDER_MINUS_ONE: U384 = NistP384::ORDER.as_ref().wrapping_sub(&U384::ONE);
        let (r, underflow) = w.borrowing_sub(&ORDER_MINUS_ONE, Limb::ZERO);
        let underflow = Choice::from((underflow.0 >> (Limb::BITS - 1)) as u8);
        Self::from_uint_unchecked(
            U384::conditional_select(w, &r, !underflow).wrapping_add(&U384::ONE),
        )
    }
}

impl ReduceNonZero<FieldBytes> for Scalar {
    #[inline]
    fn reduce_nonzero(bytes: &FieldBytes) -> Self {
        Self::reduce_nonzero(&U384::from_be_byte_array(*bytes))
    }
}

impl TryFrom<U384> for Scalar {
    type Error = Error;

    fn try_from(w: U384) -> Result<Self> {
        Self::try_from(&w)
    }
}

impl TryFrom<&U384> for Scalar {
    type Error = Error;

    fn try_from(w: &U384) -> Result<Self> {
        Self::from_uint(w).into_option().ok_or(Error)
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
    use super::{Scalar, U384};
    use crate::{FieldBytes, NistP384, NonZeroScalar};
    use elliptic_curve::{
        Curve,
        array::Array,
        ff::PrimeField,
        ops::{BatchInvert, ReduceNonZero},
    };
    use proptest::{prelude::any, prop_compose, proptest};

    primefield::test_primefield!(Scalar, U384);

    #[test]
    fn from_to_bytes_roundtrip() {
        let k: u64 = 42;
        let mut bytes = FieldBytes::default();
        bytes[40..].copy_from_slice(k.to_be_bytes().as_ref());

        let scalar = Scalar::from_repr(bytes).unwrap();
        assert_eq!(bytes, scalar.to_bytes());
    }

    /// Basic tests that multiplication works.
    #[test]
    fn multiply() {
        let one = Scalar::ONE;
        let two = one + one;
        let three = two + one;
        let six = three + three;
        assert_eq!(six, two * three);

        let minus_two = -two;
        let minus_three = -three;
        assert_eq!(two, -minus_two);

        assert_eq!(minus_three * minus_two, minus_two * minus_three);
        assert_eq!(six, minus_two * minus_three);
    }

    #[test]
    fn reduce_nonzero() {
        assert_eq!(
            Scalar::reduce_nonzero(&Array::default()).to_canonical(),
            U384::ONE
        );
        assert_eq!(
            Scalar::reduce_nonzero(&U384::ONE).to_canonical(),
            U384::from_u8(2)
        );
        assert_eq!(
            Scalar::reduce_nonzero(&U384::from_u8(2)).to_canonical(),
            U384::from_u8(3),
        );

        assert_eq!(
            Scalar::reduce_nonzero(NistP384::ORDER.as_ref()).to_canonical(),
            U384::from_u8(2),
        );
        assert_eq!(
            Scalar::reduce_nonzero(&NistP384::ORDER.wrapping_sub(&U384::from_u8(1))).to_canonical(),
            U384::ONE,
        );
        assert_eq!(
            Scalar::reduce_nonzero(&NistP384::ORDER.wrapping_sub(&U384::from_u8(2))).to_canonical(),
            NistP384::ORDER.wrapping_sub(&U384::ONE),
        );
        assert_eq!(
            Scalar::reduce_nonzero(&NistP384::ORDER.wrapping_sub(&U384::from_u8(3))).to_canonical(),
            NistP384::ORDER.wrapping_sub(&U384::from_u8(2)),
        );

        assert_eq!(
            Scalar::reduce_nonzero(&NistP384::ORDER.wrapping_add(&U384::ONE)).to_canonical(),
            U384::from_u8(3),
        );
        assert_eq!(
            Scalar::reduce_nonzero(&NistP384::ORDER.wrapping_add(&U384::from_u8(2))).to_canonical(),
            U384::from_u8(4),
        );
    }

    prop_compose! {
        fn non_zero_scalar()(bytes in any::<[u8; 48]>()) -> NonZeroScalar {
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
