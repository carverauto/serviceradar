//! JSON-specific tests.

#![cfg(feature = "alloc")]

use hex_literal::hex;
use proptest::{array::*, collection::vec, prelude::*};
use serde::Serialize;
use serde_json_core as json;
use serdect::{array, slice};

/// Example input to be serialized.
const EXAMPLE_BYTES: [u8; 16] = hex!("000102030405060708090A0B0C0D0EFF");

/// Lower-case hex serialization of [`EXAMPLE_BYTES`].
const HEX_LOWER: &str = "\"000102030405060708090a0b0c0d0eff\"";

/// Upper-case hex serialization of [`EXAMPLE_BYTES`].
const HEX_UPPER: &str = "\"000102030405060708090A0B0C0D0EFF\"";

fn serialize<T>(value: &T) -> String
where
    T: Serialize + ?Sized,
{
    // Make sure proptest doesn't fail.
    let mut buffer = [0; 2048];
    let size = json::to_slice(value, &mut buffer).unwrap();
    std::str::from_utf8(&buffer[..size]).unwrap().to_string()
}

#[test]
fn deserialize_slice() {
    let deserialized = json::from_str::<slice::HexLowerOrBin>(HEX_LOWER).unwrap().0;
    assert_eq!(deserialized.0, EXAMPLE_BYTES);

    let deserialized = json::from_str::<slice::HexUpperOrBin>(HEX_UPPER).unwrap().0;
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn deserialize_array() {
    let deserialized = json::from_str::<array::HexLowerOrBin<16>>(HEX_LOWER)
        .unwrap()
        .0;
    assert_eq!(deserialized.0, EXAMPLE_BYTES);

    let deserialized = json::from_str::<array::HexUpperOrBin<16>>(HEX_UPPER)
        .unwrap()
        .0;
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn serialize_slice() {
    let serialized = serialize(&slice::HexLowerOrBin::from(EXAMPLE_BYTES.as_ref()));
    assert_eq!(serialized, HEX_LOWER);

    let serialized = serialize(&slice::HexUpperOrBin::from(EXAMPLE_BYTES.as_ref()));
    assert_eq!(serialized, HEX_UPPER);
}

#[test]
fn serialize_array() {
    let serialized = serialize(&array::HexLowerOrBin::from(EXAMPLE_BYTES));
    assert_eq!(serialized, HEX_LOWER);

    let serialized = serialize(&array::HexUpperOrBin::from(EXAMPLE_BYTES));
    assert_eq!(serialized, HEX_UPPER);
}

proptest! {
    #[test]
    fn round_trip_slice_lower(bytes in vec(any::<u8>(), 0..1024)) {
        let serialized = serialize(&slice::HexLowerOrBin::from(bytes.as_ref()));
        let deserialized = json::from_str::<slice::HexLowerOrBin>(&serialized).unwrap().0;
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_slice_upper(bytes in vec(any::<u8>(), 0..1024)) {
        let serialized = serialize(&slice::HexUpperOrBin::from(bytes.as_ref()));
        let deserialized = json::from_str::<slice::HexUpperOrBin>(&serialized).unwrap().0;
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_array_lower(bytes in uniform32(0u8..)) {
        let serialized = serialize(&array::HexLowerOrBin::from(bytes));
        let deserialized = json::from_str::<array::HexLowerOrBin<32>>(&serialized).unwrap().0;
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_array_upper(bytes in uniform32(0u8..)) {
        let serialized = serialize(&array::HexUpperOrBin::from(bytes));
        let deserialized = json::from_str::<array::HexUpperOrBin<32>>(&serialized).unwrap().0;
        prop_assert_eq!(bytes, deserialized.0);
    }
}
