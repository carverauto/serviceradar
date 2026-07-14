//! Equivalence tests between `crypto_bigint::Int` and `num_bigint::BigInt`.

mod common;

use common::{to_bigint, to_biguint};
use crypto_bigint::{I256, Odd, U256};
use num_bigint::{BigInt, Sign, ToBigInt};
use num_modular::ModularSymbols;
use proptest::prelude::*;

fn to_int(big_int: BigInt) -> I256 {
    let mut input = [0u8; U256::BYTES];
    let (sign, encoded) = big_int.to_bytes_le();
    let l = encoded.len().min(U256::BYTES);
    input[..l].copy_from_slice(&encoded[..l]);
    let abs = *U256::from_le_slice(&input).as_int();
    if let Sign::Minus = sign {
        abs.wrapping_neg()
    } else {
        abs
    }
}

prop_compose! {
    fn int()(bytes in any::<[u8; 32]>()) -> I256 {
        *U256::from_le_slice(&bytes).as_int()
    }
}
prop_compose! {
    fn odd_uint()(mut bytes in any::<[u8; 32]>()) -> Odd<U256> {
        bytes[0] |= 1;
        U256::from_le_slice(&bytes).to_odd().unwrap()
    }
}

proptest! {
    #[test]
    fn roundtrip(a in int()) {
        prop_assert_eq!(a, to_int(to_bigint(&a)));
    }

    #[test]
    fn jacobi_symbol(f in odd_uint(), g in int()) {
        let f_bi = to_biguint(&f).to_bigint().unwrap();
        let g_bi = to_bigint(&g);

        let expected = g_bi.jacobi(&f_bi);
        let actual = g.jacobi_symbol(&f) as i8;
        let actual_vartime = g.jacobi_symbol_vartime(&f) as i8;
        prop_assert_eq!(expected, actual);
        prop_assert_eq!(expected, actual_vartime);
    }
}
