//! JSON-specific tests.

#![cfg(feature = "alloc")]

use hex_literal::hex;
use proptest::{array::*, collection::vec, prelude::*};
use serde_json as json;
use serdect::{array, slice};

/// Example input to be serialized.
const EXAMPLE_BYTES: [u8; 16] = hex!("000102030405060708090A0B0C0D0EFF");

/// Lower-case hex serialization of [`EXAMPLE_BYTES`].
const HEX_LOWER: &str = "\"000102030405060708090a0b0c0d0eff\"";

/// Upper-case hex serialization of [`EXAMPLE_BYTES`].
const HEX_UPPER: &str = "\"000102030405060708090A0B0C0D0EFF\"";

#[test]
fn deserialize_slice() {
    let deserialized = json::from_str::<slice::HexLowerOrBin>(HEX_LOWER).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);

    let deserialized = json::from_str::<slice::HexUpperOrBin>(HEX_UPPER).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn deserialize_slice_owned() {
    let deserialized = json::from_reader::<_, slice::HexLowerOrBin>(HEX_LOWER.as_bytes()).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);

    let deserialized = json::from_reader::<_, slice::HexUpperOrBin>(HEX_UPPER.as_bytes()).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn deserialize_array() {
    let deserialized = json::from_str::<array::HexLowerOrBin<16>>(HEX_LOWER).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);

    let deserialized = json::from_str::<array::HexUpperOrBin<16>>(HEX_UPPER).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn deserialize_array_owned() {
    let deserialized =
        json::from_reader::<_, array::HexLowerOrBin<16>>(HEX_LOWER.as_bytes()).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);

    let deserialized =
        json::from_reader::<_, array::HexUpperOrBin<16>>(HEX_UPPER.as_bytes()).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn serialize_slice() {
    let serialized = json::to_string(&slice::HexLowerOrBin::from(EXAMPLE_BYTES.as_ref())).unwrap();
    assert_eq!(serialized, HEX_LOWER);

    let serialized = json::to_string(&slice::HexUpperOrBin::from(EXAMPLE_BYTES.as_ref())).unwrap();
    assert_eq!(serialized, HEX_UPPER);
}

#[test]
fn serialize_array() {
    let serialized = json::to_string(&array::HexLowerOrBin::from(EXAMPLE_BYTES)).unwrap();
    assert_eq!(serialized, HEX_LOWER);

    let serialized = json::to_string(&array::HexUpperOrBin::from(EXAMPLE_BYTES)).unwrap();
    assert_eq!(serialized, HEX_UPPER);
}

proptest! {
    #[test]
    fn round_trip_slice_lower(bytes in vec(any::<u8>(), 0..1024)) {
        let serialized = json::to_string(&slice::HexLowerOrBin::from(bytes.as_ref())).unwrap();
        let deserialized = json::from_str::<slice::HexLowerOrBin>(&serialized).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_slice_upper(bytes in vec(any::<u8>(), 0..1024)) {
        let serialized = json::to_string(&slice::HexUpperOrBin::from(bytes.as_ref())).unwrap();
        let deserialized = json::from_str::<slice::HexUpperOrBin>(&serialized).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_array_lower(bytes in uniform32(0u8..)) {
        let serialized = json::to_string(&array::HexLowerOrBin::from(bytes)).unwrap();
        let deserialized = json::from_str::<array::HexLowerOrBin<32>>(&serialized).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_array_upper(bytes in uniform32(0u8..)) {
        let serialized = json::to_string(&array::HexUpperOrBin::from(bytes)).unwrap();
        let deserialized = json::from_str::<array::HexUpperOrBin<32>>(&serialized).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
    }
}
