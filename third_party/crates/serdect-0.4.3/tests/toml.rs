//! TOML-specific tests.

#![cfg(feature = "alloc")]

use hex_literal::hex;
use proptest::{array::*, collection::vec, prelude::*};
use serde::{Deserialize, Serialize};
use serdect::{array, slice};

/// Example input to be serialized.
const EXAMPLE_BYTES: [u8; 16] = hex!("000102030405060708090A0B0C0D0EFF");

/// Lower-case hex serialization of [`EXAMPLE_BYTES`].
const HEX_LOWER: &str = "\"000102030405060708090a0b0c0d0eff\"";

/// Upper-case hex serialization of [`EXAMPLE_BYTES`].
const HEX_UPPER: &str = "\"000102030405060708090A0B0C0D0EFF\"";

#[derive(Deserialize, Serialize)]
struct SliceTest {
    lower: slice::HexLowerOrBin,
    upper: slice::HexUpperOrBin,
}

#[derive(Deserialize, Serialize)]
struct ArrayTest {
    lower: array::HexLowerOrBin<16>,
    upper: array::HexUpperOrBin<16>,
}

#[test]
fn deserialize_slice() {
    let deserialized =
        toml::from_str::<SliceTest>(&format!("lower={HEX_LOWER}\nupper={HEX_UPPER}")).unwrap();

    assert_eq!(deserialized.lower.0, EXAMPLE_BYTES);
    assert_eq!(deserialized.upper.0, EXAMPLE_BYTES);
}

#[test]
fn deserialize_array() {
    let deserialized =
        toml::from_str::<ArrayTest>(&format!("lower={HEX_LOWER}\nupper={HEX_UPPER}")).unwrap();

    assert_eq!(deserialized.lower.0, EXAMPLE_BYTES);
    assert_eq!(deserialized.upper.0, EXAMPLE_BYTES);
}

#[test]
fn serialize_slice() {
    let test = SliceTest {
        lower: slice::HexLowerOrBin::from(EXAMPLE_BYTES.as_ref()),
        upper: slice::HexUpperOrBin::from(EXAMPLE_BYTES.as_ref()),
    };

    let serialized = toml::to_string(&test).unwrap();

    assert_eq!(
        serialized,
        format!("lower = {HEX_LOWER}\nupper = {HEX_UPPER}\n")
    );
}

#[test]
fn serialize_array() {
    let test = ArrayTest {
        lower: array::HexLowerOrBin::from(EXAMPLE_BYTES),
        upper: array::HexUpperOrBin::from(EXAMPLE_BYTES),
    };

    let serialized = toml::to_string(&test).unwrap();

    assert_eq!(
        serialized,
        format!("lower = {HEX_LOWER}\nupper = {HEX_UPPER}\n")
    );
}

proptest! {
    #[test]
    fn round_trip_slice_lower(bytes in vec(any::<u8>(), 0..1024)) {
        #[derive(Debug, Deserialize, PartialEq, Serialize)]
        pub struct Test {
            test: slice::HexLowerOrBin,
        }

        let test = Test { test: slice::HexLowerOrBin::from(bytes.as_ref()) };

        let serialized = toml::to_string(&test).unwrap();
        let deserialized = toml::from_str::<Test>(&serialized).unwrap();
        prop_assert_eq!(test, deserialized);
    }

    #[test]
    fn round_trip_slice_upper(bytes in vec(any::<u8>(), 0..1024)) {
        #[derive(Debug, Deserialize, PartialEq, Serialize)]
        pub struct Test {
            test: slice::HexUpperOrBin,
        }

        let test = Test { test: slice::HexUpperOrBin::from(bytes.as_ref()) };

        let serialized = toml::to_string(&test).unwrap();
        let deserialized = toml::from_str::<Test>(&serialized).unwrap();
        prop_assert_eq!(test, deserialized);
    }

    #[test]
    fn round_trip_array_lower(bytes in uniform32(0u8..)) {
        #[derive(Debug, Deserialize, PartialEq, Serialize)]
        pub struct Test {
            test: array::HexLowerOrBin<32>,
        }

        let test = Test { test: array::HexLowerOrBin::from(bytes) };

        let serialized = toml::to_string(&test).unwrap();
        let deserialized = toml::from_str::<Test>(&serialized).unwrap();
        prop_assert_eq!(test, deserialized);
    }

    #[test]
    fn round_trip_array_upper(bytes in uniform32(0u8..)) {
        #[derive(Debug, Deserialize, PartialEq, Serialize)]
        pub struct Test {
            test: array::HexUpperOrBin<32>,
        }

        let test = Test { test: array::HexUpperOrBin::from(bytes) };

        let serialized = toml::to_string(&test).unwrap();
        let deserialized = toml::from_str::<Test>(&serialized).unwrap();
        prop_assert_eq!(test, deserialized);
    }
}
