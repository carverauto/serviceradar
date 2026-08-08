//! Tests for `ctutils` integration.

#![cfg(feature = "ctutils")]

use ctutils::{Choice, CtAssign, CtEq, CtSelect};
use hybrid_array::{Array, typenum::U3};

#[test]
fn ct_assign() {
    let a: Array<u8, U3> = Array([0, 0, 0]);
    let b: Array<u8, U3> = Array([1, 2, 3]);
    let mut c = a;

    c.ct_assign(&b, Choice::FALSE);
    assert_eq!(a, c);

    c.ct_assign(&b, Choice::TRUE);
    assert_eq!(b, c);
}

#[test]
fn ct_eq() {
    let a: Array<u8, U3> = Array([0, 0, 0]);
    let b: Array<u8, U3> = Array([1, 2, 3]);

    assert!(a.ct_eq(&a).to_bool());
    assert!(!a.ct_ne(&a).to_bool());
    assert!(!a.ct_eq(&b).to_bool());
    assert!(a.ct_ne(&b).to_bool());
}

#[test]
fn ct_select() {
    let a: Array<u8, U3> = Array([0, 0, 0]);
    let b: Array<u8, U3> = Array([1, 2, 3]);

    let c = a.ct_select(&b, Choice::FALSE);
    assert_eq!(a, c);

    let d = a.ct_select(&b, Choice::TRUE);
    assert_eq!(b, d);
}
