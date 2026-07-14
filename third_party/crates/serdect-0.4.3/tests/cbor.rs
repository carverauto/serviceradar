//! CBOR-specific tests.

#![cfg(feature = "alloc")]

use ciborium::{de, ser};
use hex_literal::hex;
use proptest::{array::*, collection::vec, prelude::*};
use serde::Serialize;
use serdect::{array, slice};

/// Example input to be serialized.
/// Last byte is `0xFF` to test that no packing is performed for values under 128.
const EXAMPLE_BYTES: [u8; 16] = hex!("000102030405060708090A0B0C0D0EFF");

/// CBOR serialization of [`EXAMPLE_BYTES`] as a slice.
/// (first three bits, `0b010` denote a byte string, and the last five, `0b10000` denote the length)
const CBOR_SLICE: [u8; 17] = hex!("50000102030405060708090A0B0C0D0EFF");

#[test]
fn deserialize_slice() {
    let deserialized = de::from_reader::<slice::HexUpperOrBin, _>(CBOR_SLICE.as_ref()).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

#[test]
fn deserialize_array() {
    let deserialized = de::from_reader::<array::HexUpperOrBin<16>, _>(CBOR_SLICE.as_ref()).unwrap();
    assert_eq!(deserialized.0, EXAMPLE_BYTES);
}

fn serialize<T>(value: &T) -> Vec<u8>
where
    T: ?Sized + Serialize,
{
    let mut serialized = Vec::new();
    ser::into_writer(value, &mut serialized).unwrap();
    serialized
}

#[test]
fn serialize_slice() {
    let serialized = serialize(&slice::HexUpperOrBin::from(EXAMPLE_BYTES.as_ref()));
    assert_eq!(&serialized, &CBOR_SLICE);
}

#[test]
fn serialize_array() {
    let serialized = serialize(&array::HexUpperOrBin::from(EXAMPLE_BYTES));
    assert_eq!(&serialized, &CBOR_SLICE);
}

proptest! {
    #[test]
    fn round_trip_slice(bytes in vec(any::<u8>(), 0..1024)) {
        let serialized = serialize(&slice::HexUpperOrBin::from(bytes.as_ref()));
        let deserialized = de::from_reader::<slice::HexUpperOrBin, _>(serialized.as_slice()).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
    }

    #[test]
    fn round_trip_array(bytes in uniform32(0u8..)) {
        let serialized = serialize(&array::HexUpperOrBin::from(bytes));
        let deserialized = de::from_reader::<array::HexUpperOrBin<32>, _>(serialized.as_slice()).unwrap();
        prop_assert_eq!(bytes, deserialized.0);
        // 1 byte slice tag + 1 byte length tag + 32 bytes of data
        prop_assert_eq!(serialized.len(), 2 + 32);
    }
}
