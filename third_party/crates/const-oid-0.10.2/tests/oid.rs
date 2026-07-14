//! Tests for `ObjectIdentifier`.

// TODO(tarcieri): test full set of OID encoding constraints specified here:
// <https://misc.daniel-marschall.de/asn.1/oid_facts.html>

use const_oid::{Error, ObjectIdentifier};
use hex_literal::hex;
use std::string::ToString;

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
const EXAMPLE_OID_LARGE_ARC_0_STR: &str = "1.2.16384";
const EXAMPLE_OID_LARGE_ARC_0_BER: &[u8] = &hex!("2A818000");
const EXAMPLE_OID_LARGE_ARC_0: ObjectIdentifier =
    ObjectIdentifier::new_unwrap(crate::EXAMPLE_OID_LARGE_ARC_0_STR);

/// Example OID value with a large arc
const EXAMPLE_OID_LARGE_ARC_1_STR: &str = "1.1.1.60817410.1";
const EXAMPLE_OID_LARGE_ARC_1_BER: &[u8] = &hex!("29019D80800201");
const EXAMPLE_OID_LARGE_ARC_1: ObjectIdentifier =
    ObjectIdentifier::new_unwrap(EXAMPLE_OID_LARGE_ARC_1_STR);

/// Example OID value with a large arc (namely `u32::MAX`, the edge case)
const EXAMPLE_OID_LARGE_ARC_2_STR: &str = "1.2.4294967295";
const EXAMPLE_OID_LARGE_ARC_2_BER: &[u8] = &hex!("2A8FFFFFFF7F");
const EXAMPLE_OID_LARGE_ARC_2: ObjectIdentifier =
    ObjectIdentifier::new_unwrap(crate::EXAMPLE_OID_LARGE_ARC_2_STR);

/// Create an OID from a string.
pub fn oid(s: &str) -> ObjectIdentifier {
    ObjectIdentifier::new(s).unwrap()
}

/// 0.9.2342.19200300.100.1.1
#[test]
fn from_bytes_oid_0() {
    let oid = ObjectIdentifier::from_bytes(EXAMPLE_OID_0_BER).unwrap();
    assert_eq!(oid, EXAMPLE_OID_0);
    assert_eq!(oid.arc(0).unwrap(), 0);
    assert_eq!(oid.arc(1).unwrap(), 9);
    assert_eq!(oid.arc(2).unwrap(), 2342);
}

/// 1.2.840.10045.2.1
#[test]
fn from_bytes_oid_1() {
    let oid = ObjectIdentifier::from_bytes(EXAMPLE_OID_1_BER).unwrap();
    assert_eq!(oid, EXAMPLE_OID_1);
    assert_eq!(oid.arc(0).unwrap(), 1);
    assert_eq!(oid.arc(1).unwrap(), 2);
    assert_eq!(oid.arc(2).unwrap(), 840);
}

/// 2.16.840.1.101.3.4.1.42
#[test]
fn from_bytes_oid_2() {
    let oid = ObjectIdentifier::from_bytes(EXAMPLE_OID_2_BER).unwrap();
    assert_eq!(oid, EXAMPLE_OID_2);
    assert_eq!(oid.arc(0).unwrap(), 2);
    assert_eq!(oid.arc(1).unwrap(), 16);
    assert_eq!(oid.arc(2).unwrap(), 840);
}

/// 1.2.16384
#[test]
fn from_bytes_oid_largearc_0() {
    let oid = ObjectIdentifier::from_bytes(EXAMPLE_OID_LARGE_ARC_0_BER).unwrap();
    assert_eq!(oid, EXAMPLE_OID_LARGE_ARC_0);
    assert_eq!(oid.arc(0).unwrap(), 1);
    assert_eq!(oid.arc(1).unwrap(), 2);
    assert_eq!(oid.arc(2).unwrap(), 16384);
    assert_eq!(oid.arc(3), None);
}

/// 1.1.1.60817410.1
#[test]
fn from_bytes_oid_largearc_1() {
    let oid = ObjectIdentifier::from_bytes(EXAMPLE_OID_LARGE_ARC_1_BER).unwrap();
    assert_eq!(oid, EXAMPLE_OID_LARGE_ARC_1);
    assert_eq!(oid.arc(0).unwrap(), 1);
    assert_eq!(oid.arc(1).unwrap(), 1);
    assert_eq!(oid.arc(2).unwrap(), 1);
    assert_eq!(oid.arc(3).unwrap(), 60817410);
    assert_eq!(oid.arc(4).unwrap(), 1);
    assert_eq!(oid.arc(5), None);
}

/// 1.2.4294967295
#[test]
fn from_bytes_oid_largearc_2() {
    let oid = ObjectIdentifier::from_bytes(EXAMPLE_OID_LARGE_ARC_2_BER).unwrap();
    assert_eq!(oid, EXAMPLE_OID_LARGE_ARC_2);
    assert_eq!(oid.arc(0).unwrap(), 1);
    assert_eq!(oid.arc(1).unwrap(), 2);
    assert_eq!(oid.arc(2).unwrap(), 4294967295);
    assert_eq!(oid.arc(3), None);

    // Empty
    assert_eq!(ObjectIdentifier::from_bytes(&[]), Err(Error::Empty));
}

#[test]
fn from_str() {
    let oid0 = EXAMPLE_OID_0_STR.parse::<ObjectIdentifier>().unwrap();
    assert_eq!(oid0.arc(0).unwrap(), 0);
    assert_eq!(oid0.arc(1).unwrap(), 9);
    assert_eq!(oid0, EXAMPLE_OID_0);

    let oid1 = EXAMPLE_OID_1_STR.parse::<ObjectIdentifier>().unwrap();
    assert_eq!(oid1.arc(0).unwrap(), 1);
    assert_eq!(oid1.arc(1).unwrap(), 2);
    assert_eq!(oid1, EXAMPLE_OID_1);

    let oid2 = EXAMPLE_OID_2_STR.parse::<ObjectIdentifier>().unwrap();
    assert_eq!(oid2.arc(0).unwrap(), 2);
    assert_eq!(oid2.arc(1).unwrap(), 16);
    assert_eq!(oid2, EXAMPLE_OID_2);

    let oid_largearc0 = EXAMPLE_OID_LARGE_ARC_0_STR
        .parse::<ObjectIdentifier>()
        .unwrap();
    assert_eq!(oid_largearc0.arc(0).unwrap(), 1);
    assert_eq!(oid_largearc0.arc(1).unwrap(), 2);
    assert_eq!(oid_largearc0.arc(2).unwrap(), 16384);
    assert_eq!(oid_largearc0, EXAMPLE_OID_LARGE_ARC_0);

    let oid_largearc1 = EXAMPLE_OID_LARGE_ARC_1_STR
        .parse::<ObjectIdentifier>()
        .unwrap();
    assert_eq!(oid_largearc1.arc(0).unwrap(), 1);
    assert_eq!(oid_largearc1.arc(1).unwrap(), 1);
    assert_eq!(oid_largearc1.arc(2).unwrap(), 1);
    assert_eq!(oid_largearc1.arc(3).unwrap(), 60817410);
    assert_eq!(oid_largearc1.arc(4).unwrap(), 1);
    assert_eq!(oid_largearc1, EXAMPLE_OID_LARGE_ARC_1);

    let oid_largearc2 = EXAMPLE_OID_LARGE_ARC_2_STR
        .parse::<ObjectIdentifier>()
        .unwrap();
    assert_eq!(oid_largearc2.arc(0).unwrap(), 1);
    assert_eq!(oid_largearc2.arc(1).unwrap(), 2);
    assert_eq!(oid_largearc2.arc(2).unwrap(), 4294967295);
    assert_eq!(oid_largearc2, EXAMPLE_OID_LARGE_ARC_2);

    // Truncated
    assert_eq!(
        "1.2.840.10045.2.".parse::<ObjectIdentifier>(),
        Err(Error::TrailingDot)
    );

    // Invalid first arc
    assert_eq!(
        "3.2.840.10045.2.1".parse::<ObjectIdentifier>(),
        Err(Error::ArcInvalid { arc: 3 })
    );

    // Invalid second arc
    assert_eq!(
        "1.40.840.10045.2.1".parse::<ObjectIdentifier>(),
        Err(Error::ArcInvalid { arc: 40 })
    );
}

#[test]
fn display() {
    assert_eq!(EXAMPLE_OID_0.to_string(), EXAMPLE_OID_0_STR);
    assert_eq!(EXAMPLE_OID_1.to_string(), EXAMPLE_OID_1_STR);
    assert_eq!(EXAMPLE_OID_2.to_string(), EXAMPLE_OID_2_STR);
    assert_eq!(
        EXAMPLE_OID_LARGE_ARC_0.to_string(),
        EXAMPLE_OID_LARGE_ARC_0_STR
    );
    assert_eq!(
        EXAMPLE_OID_LARGE_ARC_1.to_string(),
        EXAMPLE_OID_LARGE_ARC_1_STR
    );
    assert_eq!(
        EXAMPLE_OID_LARGE_ARC_2.to_string(),
        EXAMPLE_OID_LARGE_ARC_2_STR
    );
}

#[test]
fn try_from_u32_slice() {
    let oid1 = ObjectIdentifier::from_arcs([1, 2, 840, 10045, 2, 1]).unwrap();
    assert_eq!(oid1.arc(0).unwrap(), 1);
    assert_eq!(oid1.arc(1).unwrap(), 2);
    assert_eq!(EXAMPLE_OID_1, oid1);

    let oid2 = ObjectIdentifier::from_arcs([2, 16, 840, 1, 101, 3, 4, 1, 42]).unwrap();
    assert_eq!(oid2.arc(0).unwrap(), 2);
    assert_eq!(oid2.arc(1).unwrap(), 16);
    assert_eq!(EXAMPLE_OID_2, oid2);

    // Invalid first arc
    assert_eq!(
        ObjectIdentifier::from_arcs([3, 2, 840, 10045, 3, 1, 7]),
        Err(Error::ArcInvalid { arc: 3 })
    );

    // Invalid second arc
    assert_eq!(
        ObjectIdentifier::from_arcs([1, 40, 840, 10045, 3, 1, 7]),
        Err(Error::ArcInvalid { arc: 40 })
    );
}

#[test]
fn as_bytes() {
    assert_eq!(EXAMPLE_OID_1.as_bytes(), EXAMPLE_OID_1_BER);
    assert_eq!(EXAMPLE_OID_2.as_bytes(), EXAMPLE_OID_2_BER);
}

#[test]
fn as_oid_ref() {
    assert_eq!(
        EXAMPLE_OID_0.as_bytes(),
        EXAMPLE_OID_0.as_oid_ref().as_bytes()
    );
}

#[test]
fn parse_empty() {
    assert_eq!(ObjectIdentifier::new(""), Err(Error::Empty));
}

#[test]
fn parse_invalid_first_arc() {
    assert_eq!(
        ObjectIdentifier::new("3.2.840.10045.3.1.7"),
        Err(Error::ArcInvalid { arc: 3 })
    );
}

#[test]
fn parse_invalid_second_arc() {
    assert_eq!(
        ObjectIdentifier::new("1.40.840.10045.3.1.7"),
        Err(Error::ArcInvalid { arc: 40 })
    );
}

#[test]
fn parse_invalid_repeat_dots() {
    assert_eq!(ObjectIdentifier::new("1.2..3.4"), Err(Error::RepeatedDot))
}

#[test]
fn parent() {
    let child = oid("1.2.3.4");
    let parent = child.parent().unwrap();
    assert_eq!(parent, oid("1.2.3"));

    let parent = parent.parent().unwrap();
    assert_eq!(parent, oid("1.2"));
    assert_eq!(parent.parent(), None);
}

#[test]
fn push_arc() {
    let parent = oid("1.2.3");
    assert_eq!(parent.push_arc(4).unwrap(), oid("1.2.3.4"));
}

#[test]
fn starts_with() {
    let child = ObjectIdentifier::new("1.2.3.4.5").unwrap();
    assert!(child.starts_with(oid("1.2.3.4.5")));
    assert!(child.starts_with(oid("1.2.3.4")));
    assert!(child.starts_with(oid("1.2.3")));

    assert!(!child.starts_with(oid("1.2.4")));
    assert!(!child.starts_with(oid("2.2.3")));
    assert!(!child.starts_with(oid("1.2.3.4.5.6")));
}
