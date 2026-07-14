//! Equivalence tests between `crypto_bigint::BoxedMontyForm` and `num-bigint`.

#![cfg(feature = "alloc")]

mod common;

use common::to_biguint;
use crypto_bigint::{
    BoxedUint, Integer, Limb, Odd,
    modular::{BoxedMontyForm, BoxedMontyParams},
};
use num_bigint::BigUint;
use num_integer::Integer as _;
use num_modular::ModularUnaryOps;
use proptest::prelude::*;

fn retrieve_biguint(monty_form: &BoxedMontyForm) -> BigUint {
    to_biguint(&monty_form.retrieve())
}

fn reduce(n: &BoxedUint, p: BoxedMontyParams) -> BoxedMontyForm {
    let n_reduced = n.rem_vartime(p.modulus().as_nz_ref());

    BoxedMontyForm::new(n_reduced, p)
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
    /// Generate a random odd modulus.
    fn modulus()(mut n in uint()) -> BoxedMontyParams {
        if n.is_even().into() {
            n = n.wrapping_add(&BoxedUint::one());
        }

        BoxedMontyParams::new(Odd::new(n).expect("modulus should be odd"))
    }
}
prop_compose! {
    /// Generate a single Montgomery form integer.
    fn monty_form()(a in uint(), n in modulus()) -> BoxedMontyForm {
        reduce(&a, n.clone())
    }
}
prop_compose! {
    /// Generate two Montgomery form integers with a common modulus.
    fn monty_form_pair()(a in uint(), b in uint(), n in modulus()) -> (BoxedMontyForm, BoxedMontyForm) {
        (reduce(&a, n.clone()), reduce(&b, n.clone()))
    }
}

proptest! {
    #[test]
    fn new(mut n in uint()) {
        if n.is_even().into() {
            n = n.wrapping_add(&BoxedUint::one());
        }

        let n = Odd::new(n).expect("ensured odd");
        let params1 = BoxedMontyParams::new(n.clone());
        let params2 = BoxedMontyParams::new_vartime(n);
        prop_assert_eq!(params1, params2);
    }

    #[test]
    fn invert(x in uint(), n in modulus()) {
        let x = reduce(&x, n.clone());
        let actual = Option::<BoxedMontyForm>::from(x.invert()).map(|a| a.retrieve());

        let x_bi = retrieve_biguint(&x);
        let n_bi = to_biguint(n.modulus());
        let expected = x_bi.invm(&n_bi);

        match (expected, actual) {
            (Some(exp), Some(act)) => prop_assert_eq!(exp, to_biguint(&act)),
            (None, None) => (),
            (exp, _) => {
                if exp.is_some() && x.is_zero().into() {
                     // we disagree on whether the inverse of zero exists
                } else {
                    panic!("disagreement on if modular inverse exists")
                }
            }
        }
    }

    #[test]
    fn add((a, b) in monty_form_pair()) {
        let p = a.params().modulus();
        let actual = &a + &b;
        prop_assert!(actual.as_montgomery() < a.params().modulus());

        let a_bi = retrieve_biguint(&a);
        let b_bi = retrieve_biguint(&b);
        let p_bi = to_biguint(&p);
        let expected = (a_bi + b_bi) % p_bi;

        prop_assert_eq!(retrieve_biguint(&actual), expected);
    }

    #[test]
    fn double(a in monty_form()) {
        let p = a.params().modulus();
        let actual = a.double();
        prop_assert!(actual.as_montgomery() < a.params().modulus());

        let a_bi = retrieve_biguint(&a);
        let p_bi = to_biguint(&p);
        let expected = (a_bi << 1) % p_bi;

        prop_assert_eq!(retrieve_biguint(&actual), expected);
    }

    #[test]
    fn sub((a, b) in monty_form_pair()) {
        let p = a.params().modulus();
        let actual = &a - &b;
        prop_assert!(actual.as_montgomery() < a.params().modulus());

        let a_bi = retrieve_biguint(&a);
        let b_bi = retrieve_biguint(&b);
        let p_bi = to_biguint(&p);
        let expected = if a_bi >= b_bi {
            (a_bi - b_bi) % &p_bi
        } else {
            (&p_bi - (b_bi - a_bi)) % &p_bi
        };

        prop_assert_eq!(retrieve_biguint(&actual), expected);
    }

    #[test]
    fn mul((a, b) in monty_form_pair()) {
        let p = a.params().modulus();
        let actual = &a * &b;
        prop_assert!(actual.as_montgomery() < a.params().modulus());

        let a_bi = retrieve_biguint(&a);
        let b_bi = retrieve_biguint(&b);
        let p_bi = to_biguint(&p);
        let expected = (a_bi * b_bi) % p_bi;

        prop_assert_eq!(retrieve_biguint(&actual), expected);
    }

    #[test]
    fn square(a in monty_form()) {
        let p = a.params().modulus();
        let actual = a.square();
        prop_assert!(actual.as_montgomery() < a.params().modulus());

        let a_bi = retrieve_biguint(&a);
        let p_bi = to_biguint(&p);
        let expected = a_bi.sqm(&p_bi);

        prop_assert_eq!(retrieve_biguint(&actual), expected);
    }

    #[test]
    fn pow(a in uint(), b in uint(), n in modulus()) {
        let a = reduce(&a, n.clone());
        let actual = a.pow(&b);

        let a_bi = retrieve_biguint(&a);
        let b_bi = to_biguint(&b);
        let n_bi = to_biguint(n.modulus());
        let expected = a_bi.modpow(&b_bi, &n_bi);

        prop_assert_eq!(retrieve_biguint(&actual), expected);
    }

    #[test]
    fn div_by_2(a in monty_form()) {
        let actual = a.div_by_2();
        let mut actual_inplace = a.clone();
        actual_inplace.div_by_2_assign();

        let p = a.params().modulus();
        let a_bi = retrieve_biguint(&a);
        let p_bi = to_biguint(&p);

        let expected = if a_bi.is_odd() {
            (a_bi + p_bi) >> 1
        }
        else {
            a_bi >> 1
        };

        prop_assert_eq!(&retrieve_biguint(&actual), &expected);
        prop_assert_eq!(&retrieve_biguint(&actual_inplace), &expected);
    }
}
