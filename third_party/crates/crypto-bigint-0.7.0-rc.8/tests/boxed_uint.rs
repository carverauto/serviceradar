//! Equivalence tests between `crypto_bigint::BoxedUint` and `num_bigint::BigUint`.

#![cfg(feature = "alloc")]

mod common;

use common::to_biguint;
use crypto_bigint::{BitOps, BoxedUint, CheckedAdd, Gcd, Integer, Limb, NonZero, Odd, Resize};
use num_bigint::BigUint;
use num_integer::Integer as _;
use num_modular::ModularUnaryOps;
use num_traits::identities::One;
use proptest::prelude::*;
use subtle::Choice;

fn to_uint(big_uint: BigUint) -> BoxedUint {
    let bytes = big_uint.to_bytes_be();
    let pad_count = Limb::BYTES - (bytes.len() % Limb::BYTES);
    let mut padded_bytes = vec![0u8; pad_count];
    padded_bytes.extend_from_slice(&bytes);
    BoxedUint::from_be_slice(&padded_bytes, padded_bytes.len() as u32 * 8).unwrap()
}

fn reduce(x: &BoxedUint, n: &NonZero<BoxedUint>) -> BoxedUint {
    x.rem_vartime(n)
}

prop_compose! {
    /// Generate a random `BoxedUint`.
    fn uint()(mut bytes in any::<Vec<u8>>()) -> BoxedUint {
        let extra = bytes.len() % Limb::BYTES;
        let bytes_precision = bytes.len() - extra;
        bytes.truncate(bytes_precision);
        BoxedUint::from_be_slice(&bytes, bytes_precision as u32 * 8).unwrap()
    }
}
prop_compose! {
    /// Generate a pair of random `BoxedUint`s with the same precision.
    fn uint_pair()(a in uint(), b in uint()) -> (BoxedUint, BoxedUint) {
        let bits_precision = core::cmp::max(a.bits_precision(), b.bits_precision());
        (a.resize(bits_precision), b.resize(bits_precision))
    }
}
prop_compose! {
    /// Generate a random odd modulus.
    fn modulus()(n in uint()) -> Odd<BoxedUint> {
        if n.is_even().into() {
            n.wrapping_add(&BoxedUint::one())
        } else {
            n
        }.to_odd().expect("odd by construction")
    }
}

proptest! {
    #[test]
    fn roundtrip(a in uint()) {
        prop_assert_eq!(&a, &to_uint(to_biguint(&a)));
    }

    #[test]
    fn bits(a in uint()) {
        let expected = to_biguint(&a).bits() as u32;
        prop_assert_eq!(expected, a.bits());
        prop_assert_eq!(expected, a.bits_vartime());
    }

    #[test]
    fn checked_add(a in uint(), b in uint()) {
        let a_bi = to_biguint(&a);
        let b_bi = to_biguint(&b);
        let expected = a_bi + b_bi;

        match Option::<BoxedUint>::from(a.checked_add(&b)) {
            Some(actual) => prop_assert_eq!(expected, to_biguint(&actual)),
            None => {
                let max = BoxedUint::max(a.bits_precision());
                prop_assert!(expected > to_biguint(&max));
            }
        }
    }

    #[test]
    fn checked_div((a, b) in uint_pair()) {
        let actual = a.checked_div(&b);

        if b.is_zero().into() {
            prop_assert!(bool::from(actual.is_none()));
        } else {
            let a_bi = to_biguint(&a);
            let b_bi = to_biguint(&b);
            let expected = &a_bi / &b_bi;
            prop_assert_eq!(expected, to_biguint(&actual.unwrap()));
        }
    }

    #[test]
    fn div_rem(a in uint(), mut b in uint()) {
        if b.is_zero().into() {
            b = b.wrapping_add(&BoxedUint::one());
        }

        let a_bi = to_biguint(&a);
        let b_bi = to_biguint(&b);
        let expected_quotient = &a_bi / &b_bi;
        let expected_remainder = a_bi % b_bi;

        let (actual_quotient, actual_remainder) = a.div_rem(&NonZero::new(b).unwrap());
        prop_assert_eq!(expected_quotient, to_biguint(&actual_quotient));
        prop_assert_eq!(expected_remainder, to_biguint(&actual_remainder));
    }

    #[test]
    fn div_rem_vartime((a, mut b) in uint_pair()) {
        if b.is_zero().into() {
            b = b.wrapping_add(&BoxedUint::one());
        }

        let a_bi = to_biguint(&a);
        let b_bi = to_biguint(&b);
        let expected_quotient = &a_bi / &b_bi;
        let expected_remainder = a_bi % b_bi;

        let (actual_quotient, actual_remainder) = a.div_rem_vartime(&NonZero::new(b).unwrap());
        prop_assert_eq!(expected_quotient, to_biguint(&actual_quotient));
        prop_assert_eq!(expected_remainder, to_biguint(&actual_remainder));
    }

    #[test]
    fn gcd((f, g) in uint_pair()) {
        let f_bi = to_biguint(&f);
        let g_bi = to_biguint(&g);

        let expected = to_uint(f_bi.gcd(&g_bi));
        let actual = f.gcd(&g);
        prop_assert_eq!(expected, actual);
    }

    #[test]
    fn invert_mod2k(mut a in uint(), k in any::<u32>()) {
        a.set_bit(0, Choice::from(1)); // make odd
        let k = k % (a.bits() + 1);
        let a_bi = to_biguint(&a);
        let m_bi = BigUint::one() << k as usize;

        let actual = a.invert_mod2k(k).0;
        let (actual_vartime, exists) = a.invert_mod2k_vartime(k);
        prop_assert!(bool::from(exists));
        prop_assert_eq!(&actual, &actual_vartime);

        if k == 0 {
            prop_assert_eq!(&actual, &BoxedUint::zero_with_precision(a.bits_precision()));
        }
        else {
            let inv_bi = to_biguint(&actual);
            let res = (inv_bi * a_bi) % m_bi;
            prop_assert_eq!(res, BigUint::one());
        }
    }

    #[test]
    fn mod_invert((mut a, mut b) in uint_pair()) {
        if a.is_zero().into() {
            // we disagree on whether the inverse of zero exists
            a = BoxedUint::one_with_precision(a.bits_precision());
        }
        if b.is_even().into() {
            b = b.wrapping_add(&BoxedUint::one());
        }

        let b = b.to_odd().unwrap();

        let a_bi = to_biguint(&a);
        let b_bi = to_biguint(&b);
        let expected = a_bi.invm(&b_bi);
        let actual = Option::<BoxedUint>::from(a.invert_odd_mod(&b));

        match (expected, actual) {
            (Some(exp), Some(act)) => prop_assert_eq!(exp, to_biguint(&act)),
            (None, None) => (),
            (_, _) => panic!("disagreement on if modular inverse exists")
        }
    }

    #[test]
    fn mul_mod(a in uint(), b in uint(), n in modulus()) {
        let a = reduce(&a, n.as_nz_ref());
        let b = reduce(&b, n.as_nz_ref());

        let a_bi = to_biguint(&a);
        let b_bi = to_biguint(&b);
        let n_bi = to_biguint(&n);

        let expected = to_uint((a_bi * b_bi) % n_bi);
        let actual = a.mul_mod(&b, n.as_nz_ref());
        prop_assert_eq!(expected, actual);
    }

    #[test]
    fn widening_mul(a in uint(), b in uint()) {
        let a_bi = to_biguint(&a);
        let b_bi = to_biguint(&b);

        let expected = a_bi * b_bi;
        let actual = a.mul(&b);

        prop_assert_eq!(expected, to_biguint(&actual));
    }

    #[test]
    fn widening_square(a in uint()) {
        let a_bi = to_biguint(&a);

        let expected = a_bi.pow(2);
        let actual = a.square();

        prop_assert_eq!(expected, to_biguint(&actual));
    }

    #[test]
    fn wrapping_mul(a in uint(), b in uint()) {
        let a_bi = to_biguint(&a);
        let b_bi = to_biguint(&b);

        let cap = BigUint::from(2u32).pow(a.bits_precision());
        let expected = (a_bi * b_bi) % cap;
        let actual = a.wrapping_mul(&b);

        prop_assert_eq!(expected, to_biguint(&actual));
    }

    #[test]
    fn wrapping_square(a in uint()) {
        let a_bi = to_biguint(&a);

        let cap = BigUint::from(2u32).pow(a.bits_precision());
        let expected = a_bi.pow(2) % cap;
        let actual = a.wrapping_square();

        prop_assert_eq!(expected, to_biguint(&actual));
    }

    #[test]
    fn rem((a, b) in uint_pair()) {
        if bool::from(!b.is_zero()) {
            let a_bi = to_biguint(&a);
            let b_bi = to_biguint(&b);

            let expected = a_bi % b_bi;
            let actual = a.rem(&NonZero::new(b).unwrap());

            prop_assert_eq!(expected, to_biguint(&actual));
        }
    }

    #[test]
    fn rem_vartime((a, b) in uint_pair()) {
        if bool::from(!b.is_zero()) {
            let a_bi = to_biguint(&a);
            let b_bi = to_biguint(&b);

            let expected = a_bi % b_bi;
            let actual = a.rem_vartime(&NonZero::new(b).unwrap());

            prop_assert_eq!(expected, to_biguint(&actual));
        }
    }

    #[test]
    fn shl(a in uint(), shift in any::<u16>()) {
        let a_bi = to_biguint(&a);

        // Add a 50% probability of overflow.
        let shift = u32::from(shift) % (a.bits_precision() * 2);

        let expected = to_uint((a_bi << shift as usize) & ((BigUint::one() << a.bits_precision() as usize) - BigUint::one()));
        let (actual, overflow) = a.overflowing_shl(shift);

        prop_assert_eq!(&expected, &actual);
        if shift >= a.bits_precision() {
            prop_assert_eq!(actual, BoxedUint::zero());
            prop_assert!(bool::from(overflow));
        }
    }

    #[test]
    fn shl_vartime(a in uint(), shift in any::<u16>()) {
        let a_bi = to_biguint(&a);

        // Add a 50% probability of overflow.
        let shift = u32::from(shift) % (a.bits_precision() * 2);

        let expected = to_uint((a_bi << shift as usize) & ((BigUint::one() << a.bits_precision() as usize) - BigUint::one()));
        let actual = a.shl_vartime(shift);

        if shift >= a.bits_precision() {
            prop_assert!(actual.is_none());
        }
        else {
            prop_assert_eq!(expected, actual.unwrap());
        }
    }

    #[test]
    fn shr(a in uint(), shift in any::<u16>()) {
        let a_bi = to_biguint(&a);

        // Add a 50% probability of overflow.
        let shift = u32::from(shift) % (a.bits_precision() * 2);

        let expected = to_uint(a_bi >> shift as usize);
        let (actual, overflow) = a.overflowing_shr(shift);

        prop_assert_eq!(&expected, &actual);
        if shift >= a.bits_precision() {
            prop_assert_eq!(actual, BoxedUint::zero());
            prop_assert!(bool::from(overflow));
        }
    }

    #[test]
    fn shr_vartime(a in uint(), shift in any::<u16>()) {
        let a_bi = to_biguint(&a);

        // Add a 50% probability of overflow.
        let shift = u32::from(shift) % (a.bits_precision() * 2);

        let expected = to_uint(a_bi >> shift as usize);
        let actual = a.shr_vartime(shift);

        if shift >= a.bits_precision() {
            prop_assert!(actual.is_none());
        }
        else {
            prop_assert_eq!(expected, actual.unwrap());
        }
    }

    #[test]
    fn radix_encode_vartime(a in uint(), radix in 2u32..=36) {
        let a_bi = to_biguint(&a);

        let expected_enc = a_bi.to_str_radix(radix);
        let actual_enc = a.to_string_radix_vartime(radix);
        prop_assert_eq!(&expected_enc, &actual_enc);

        let decoded = BoxedUint::from_str_radix_vartime(&actual_enc, radix).expect("decoding error");
        let dec_bi = to_biguint(&decoded);
        prop_assert_eq!(dec_bi, a_bi);

    }

    #[test]
    fn from_be_slice_vartime(a in uint()) {
        let a_bytes = a.to_be_bytes_trimmed_vartime();
        let b = BoxedUint::from_be_slice_vartime(&a_bytes);
        prop_assert_eq!(a, b);
    }

    #[test]
    fn from_le_slice_vartime(a in uint()) {
        let a_bytes = a.to_le_bytes_trimmed_vartime();
        let b = BoxedUint::from_le_slice_vartime(&a_bytes);
        prop_assert_eq!(a, b);
    }
}
