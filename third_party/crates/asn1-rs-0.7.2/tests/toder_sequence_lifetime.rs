#![cfg(feature = "std")]

use asn1_rs::*;
use hex_literal::hex;

#[derive(Debug, PartialEq, DerSequence, ToDerSequence)]
#[debug_derive]
pub struct T1<'a> {
    a: u32,
    b: u16,
    c: u16,
    d: &'a str,
}

#[test]
fn toder_sequence_lifetime() {
    let input = &hex!("300f0201 01020102 020103 0c0461626364");
    let (rem, t1) = T1::from_der(input).expect("parsing failed");
    assert!(rem.is_empty());
    assert_eq!(
        t1,
        T1 {
            a: 1,
            b: 2,
            c: 3,
            d: "abcd"
        }
    );
    // serialize back data
    let output = t1.to_der_vec().expect("serialization failed");
    assert_eq!(&input[..], output);
}
