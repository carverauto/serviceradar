//! Equivalence tests for Bernstein-Yang inversions.

mod common;

use common::to_biguint;
use crypto_bigint::{Odd, U256};
use num_bigint::BigUint;
use num_integer::Integer;
use num_traits::One;
use proptest::prelude::*;

#[cfg(feature = "alloc")]
use crypto_bigint::{BoxedUint, Resize};

prop_compose! {
    fn uint()(bytes in any::<[u8; 32]>()) -> U256 {
        U256::from_le_slice(&bytes)
    }
}

prop_compose! {
    fn odd_uint()(bytes in any::<[u8; 32]>()) -> Odd<U256> {
        let val = U256::from_le_slice(&bytes);
        (val | U256::ONE).to_odd().unwrap()
    }
}

#[cfg(feature = "alloc")]
prop_compose! {
    fn boxed_uint()(byte_vec in any::<Vec<u8>>()) -> BoxedUint {
        let mut bytes = byte_vec.as_slice();

        if bytes.len() > 32 {
            bytes = &bytes[..32];
        }

        BoxedUint::from_le_slice(bytes, 256).unwrap()
    }
}

proptest! {
    #[test]
    fn invert_odd_mod(x in uint(), m in odd_uint()) {
        let x_bi = to_biguint(&x);
        let m_bi = to_biguint(&m);

        let expected_is_some = x_bi.gcd(&m_bi) == BigUint::one();
        let actual = x.invert_odd_mod(&m);

        prop_assert_eq!(expected_is_some, bool::from(actual.is_some()));

        if let Some(actual) = Option::<U256>::from(actual) {
            let inv_bi = to_biguint(&actual);
            let res = (inv_bi * x_bi) % m_bi;
            prop_assert_eq!(res, BigUint::one());

            // check vartime implementation equivalence
            let actual_vartime = x.invert_odd_mod_vartime(&m).unwrap();
            prop_assert_eq!(actual, actual_vartime);
        }
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn boxed_invert_mod(x in boxed_uint()) {
        /// Example prime number (NIST P-256 curve order)
        const P: Odd<U256> =
            Odd::<U256>::from_be_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");

        let p = Odd::<BoxedUint>::from(&P);
        let x = x.rem_vartime(p.as_nz_ref()).resize(p.bits_precision());

        let x_bi = to_biguint(&x);
        let p_bi = to_biguint(&P);

        let expected_is_some = x_bi.gcd(&p_bi) == BigUint::one();
        let actual = x.invert_mod(p.as_nz_ref());

        prop_assert_eq!(expected_is_some, bool::from(actual.is_some()));

        if let Some(actual) = Option::<BoxedUint>::from(actual) {
            let inv_bi = to_biguint(&actual);
            let res = (inv_bi * x_bi) % p_bi;
            prop_assert_eq!(res, BigUint::one());

            // check vartime implementation equivalence
            let actual_vartime = x.invert_mod(p.as_nz_ref()).unwrap();
            prop_assert_eq!(actual, actual_vartime);
        }
    }
}
