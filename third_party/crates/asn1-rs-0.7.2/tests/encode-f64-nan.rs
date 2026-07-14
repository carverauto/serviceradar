#![cfg(feature = "std")]

use asn1_rs::*;

#[test]
fn test_encode_nan() {
    let _res = Real::new(f64::NAN);
}
