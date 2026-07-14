//! Affine arithmetic tests.

// TODO(tarcieri): point compaction support

#![cfg(all(feature = "arithmetic", feature = "test-vectors"))]

use elliptic_curve::{
    group::{GroupEncoding, prime::PrimeCurveAffine},
    sec1::{FromEncodedPoint, ToEncodedPoint},
};
use hex_literal::hex;

use p384::{AffinePoint, EncodedPoint};

const UNCOMPRESSED_BASEPOINT: &[u8] = &hex!(
    "04 aa87ca22 be8b0537 8eb1c71e f320ad74 6e1d3b62 8ba79b98
        59f741e0 82542a38 5502f25d bf55296c 3a545e38 72760ab7
        3617de4a 96262c6f 5d9e98bf 9292dc29 f8f41dbd 289a147c
        e9da3113 b5f0b8c0 0a60b1ce 1d7e819d 7a431d7c 90ea0e5f"
);

const COMPRESSED_BASEPOINT: &[u8] = &hex!(
    "03 aa87ca22 be8b0537 8eb1c71e f320ad74 6e1d3b62 8ba79b98
        59f741e0 82542a38 5502f25d bf55296c 3a545e38 72760ab7"
);

#[test]
fn uncompressed_round_trip() {
    let pubkey = EncodedPoint::from_bytes(UNCOMPRESSED_BASEPOINT).unwrap();
    let point = AffinePoint::from_encoded_point(&pubkey).unwrap();
    assert_eq!(point, AffinePoint::generator());

    let res: EncodedPoint = point.into();
    assert_eq!(res, pubkey);
}

#[test]
fn compressed_round_trip() {
    let pubkey = EncodedPoint::from_bytes(COMPRESSED_BASEPOINT).unwrap();
    let point = AffinePoint::from_encoded_point(&pubkey).unwrap();
    assert_eq!(point, AffinePoint::generator());

    let res: EncodedPoint = point.to_encoded_point(true);
    assert_eq!(res, pubkey);
}

#[test]
fn uncompressed_to_compressed() {
    let encoded = EncodedPoint::from_bytes(UNCOMPRESSED_BASEPOINT).unwrap();

    let res = AffinePoint::from_encoded_point(&encoded)
        .unwrap()
        .to_encoded_point(true);

    assert_eq!(res.as_bytes(), COMPRESSED_BASEPOINT);
}

#[test]
fn compressed_to_uncompressed() {
    let encoded = EncodedPoint::from_bytes(COMPRESSED_BASEPOINT).unwrap();

    let res = AffinePoint::from_encoded_point(&encoded)
        .unwrap()
        .to_encoded_point(false);

    assert_eq!(res.as_bytes(), UNCOMPRESSED_BASEPOINT);
}

#[test]
fn affine_negation() {
    let basepoint = AffinePoint::generator();
    assert_eq!(-(-basepoint), basepoint);
}

#[test]
fn identity_encoding() {
    // This is technically an invalid SEC1 encoding, but is preferable to panicking.
    assert_eq!([0; 49], AffinePoint::IDENTITY.to_bytes().as_slice());
    assert!(bool::from(
        AffinePoint::from_bytes(&AffinePoint::IDENTITY.to_bytes())
            .unwrap()
            .is_identity()
    ))
}
