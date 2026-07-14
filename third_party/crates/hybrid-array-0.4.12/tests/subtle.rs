//! Tests for `subtle` crate integration.

#![cfg(feature = "subtle")]

use hybrid_array::{Array, typenum::U3};
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};

#[test]
fn constant_time_eq() {
    let a: Array<u8, U3> = Array([0, 0, 0]);
    let b: Array<u8, U3> = Array([1, 2, 3]);

    assert!(bool::from(a.ct_eq(&a)));
    assert!(!bool::from(a.ct_ne(&a)));
    assert!(!bool::from(a.ct_eq(&b)));
    assert!(bool::from(a.ct_ne(&b)));
}

#[test]
fn conditional_select() {
    let a: Array<u8, U3> = Array([0, 0, 0]);
    let b: Array<u8, U3> = Array([1, 2, 3]);

    let c = Array::conditional_select(&a, &b, Choice::from(0));
    assert_eq!(a, c);

    let d = Array::conditional_select(&a, &b, Choice::from(1));
    assert_eq!(b, d);
}
