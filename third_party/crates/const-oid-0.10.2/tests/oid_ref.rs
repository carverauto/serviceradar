//! Tests for `ObjectIdentifierRef`.

use const_oid::{Error, ObjectIdentifier, ObjectIdentifierRef};
use hex_literal::hex;

/// Example OID value with a root arc of `0` (and large arc).
const EXAMPLE_OID_0_STR: &str = "0.9.2342.19200300.100.1.1";
const EXAMPLE_OID_0_BER: &[u8] = &hex!("0992268993F22C640101");
const EXAMPLE_OID_0: ObjectIdentifier = ObjectIdentifier::new_unwrap(EXAMPLE_OID_0_STR);

/// Example OID value with a root arc of `1`.
const EXAMPLE_OID_1_STR: &str = "1.2.840.10045.2.1";
const EXAMPLE_OID_1_BER: &[u8] = &hex!("2A8648CE3D0201");
const EXAMPLE_OID_1: ObjectIdentifier = ObjectIdentifier::new_unwrap(EXAMPLE_OID_1_STR);

/// Example OID value with a root arc of `2`.
const EXAMPLE_OID_2_STR: &str = "2.16.840.1.101.3.4.1.42";
const EXAMPLE_OID_2_BER: &[u8] = &hex!("60864801650304012A");
const EXAMPLE_OID_2: ObjectIdentifier = ObjectIdentifier::new_unwrap(EXAMPLE_OID_2_STR);

/// Example OID value with a large arc
const EXAMPLE_OID_LARGE_ARC_STR: &str = "0.9.2342.19200300.100.1.1";
const EXAMPLE_OID_LARGE_ARC_BER: &[u8] = &hex!("0992268993F22C640101");
const EXAMPLE_OID_LARGE_ARC: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("0.9.2342.19200300.100.1.1");

#[test]
fn from_bytes() {
    let oid0 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_0_BER).unwrap();
    assert_eq!(oid0.arc(0).unwrap(), 0);
    assert_eq!(oid0.arc(1).unwrap(), 9);
    assert_eq!(oid0, &EXAMPLE_OID_0);

    let oid1 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_1_BER).unwrap();
    assert_eq!(oid1.arc(0).unwrap(), 1);
    assert_eq!(oid1.arc(1).unwrap(), 2);
    assert_eq!(oid1, &EXAMPLE_OID_1);

    let oid2 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_2_BER).unwrap();
    assert_eq!(oid2.arc(0).unwrap(), 2);
    assert_eq!(oid2.arc(1).unwrap(), 16);
    assert_eq!(oid2, &EXAMPLE_OID_2);

    let oid3 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_LARGE_ARC_BER).unwrap();
    assert_eq!(oid3.arc(0).unwrap(), 0);
    assert_eq!(oid3.arc(1).unwrap(), 9);
    assert_eq!(oid3.arc(2).unwrap(), 2342);
    assert_eq!(oid3.arc(3).unwrap(), 19200300);
    assert_eq!(oid3.arc(4).unwrap(), 100);
    assert_eq!(oid3.arc(5).unwrap(), 1);
    assert_eq!(oid3.arc(6).unwrap(), 1);
    assert_eq!(oid3, &EXAMPLE_OID_LARGE_ARC);

    // Empty
    assert_eq!(ObjectIdentifierRef::from_bytes(&[]), Err(Error::Empty));
}

#[test]
fn display() {
    let oid0 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_0_BER).unwrap();
    assert_eq!(oid0.to_string(), EXAMPLE_OID_0_STR);

    let oid1 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_1_BER).unwrap();
    assert_eq!(oid1.to_string(), EXAMPLE_OID_1_STR);

    let oid2 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_2_BER).unwrap();
    assert_eq!(oid2.to_string(), EXAMPLE_OID_2_STR);

    let oid3 = ObjectIdentifierRef::from_bytes(EXAMPLE_OID_LARGE_ARC_BER).unwrap();
    assert_eq!(oid3.to_string(), EXAMPLE_OID_LARGE_ARC_STR);
}
