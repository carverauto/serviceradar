//! messagepack-specific tests.

#![cfg(feature = "alloc")]

use hex_literal::hex;
use proptest::{array::*, collection::vec, prelude::*};
use serdect::{array, slice};

/// Example input to be serialized.
/// Last byte is `0xFF` to test that no packing is performed for values under 128.
const EXAMPLE_BYTES: [u8; 16] = hex!("000102030405060708090A0B0C0D0EFF");

/// messagepack serialization of [`EXAMPLE_BYTES`] as a slice.
const MESSAGEPACK_SLICE: [u8; 18] = hex!("C410000102030405060708090A0B0C0D0EFF");

#[test]
fn deserialize_slice() {
    let deserialized =
        rmp_serde::decode::from_slice::<slice::HexUpperOrBin>(&MESSAGEPACK_SLICE).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn deserialize_array() {
    let deserialized =
        rmp_serde::decode::from_slice::<array::HexUpperOrBin<16>>(&MESSAGEPACK_SLICE).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn serialize_slice() {
    let serialized =
        rmp_serde::encode::to_vec(&slice::HexUpperOrBin::from(EXAMPLE_BYTES.as_ref())).unwrap();
    assert_eq!(&serialized, &MESSAGEPACK_SLICE);
}

#[test]
fn serialize_array() {
    let serialized = rmp_serde::encode::to_vec(&array::HexUpperOrBin::from(EXAMPLE_BYTES)).unwrap();
    assert_eq!(&serialized, &MESSAGEPACK_SLICE);
}

proptest! {
    #[test]
    fn round_trip_slice(bytes in vec(any::<u8>(), 0..1024)) {
        let serialized = rmp_serde::encode::to_vec(&slice::HexUpperOrBin::from(bytes.as_ref())).unwrap();
        let deserialized = rmp_serde::decode::from_slice::<slice::HexUpperOrBin>(&serialized).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_array(bytes in uniform32(0u8..)) {
        let serialized = rmp_serde::encode::to_vec(&array::HexUpperOrBin::from(bytes)).unwrap();
        let deserialized = rmp_serde::decode::from_slice::<array::HexUpperOrBin<32>>(&serialized).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
        // 1 byte slice tag + 1 byte length tag + 32 bytes of data
        prop_assert_eq!(serialized.len(), 2 + 32);
    }
}
