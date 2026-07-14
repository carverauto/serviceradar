#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg"
)]
#![forbid(unsafe_code)]
#![warn(missing_docs, rust_2018_idioms, unused_qualifications)]
#![doc = include_str!("../README.md")]

//! ## `serde` support
//!
//! When the `serde` feature of this crate is enabled, `Serialize` and
//! `Deserialize` are impl'd for the following types:
//!
//! - [`AffinePoint`]
//! - [`ProjectivePoint`]
//! - [`Scalar`]
//! - [`ecdsa::VerifyingKey`]
//!
//! Please see type-specific documentation for more information.

#[cfg(feature = "arithmetic")]
mod arithmetic;

#[cfg(feature = "ecdh")]
pub mod ecdh;

#[cfg(feature = "ecdsa-core")]
pub mod ecdsa;

#[cfg(any(feature = "test-vectors", test))]
pub mod test_vectors;

pub use elliptic_curve::{
    self,
    bigint::{Odd, U384},
    consts::U48,
};

#[cfg(feature = "arithmetic")]
pub use arithmetic::{AffinePoint, ProjectivePoint, scalar::Scalar};

#[cfg(feature = "expose-field")]
pub use arithmetic::field::FieldElement;

#[cfg(feature = "pkcs8")]
pub use elliptic_curve::pkcs8;

use elliptic_curve::{FieldBytesEncoding, array::Array, bigint::ArrayEncoding, consts::U49};

/// Order of NIST P-384's elliptic curve group (i.e. scalar modulus) in hexadecimal.
const ORDER_HEX: &str = "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973";

/// NIST P-384 elliptic curve.
#[derive(Copy, Clone, Debug, Default, Eq, PartialEq, PartialOrd, Ord)]
pub struct NistP384;

impl elliptic_curve::Curve for NistP384 {
    /// 48-byte serialized field elements.
    type FieldBytesSize = U48;

    /// 384-bit integer type used for internally representing field elements.
    type Uint = U384;

    /// Order of NIST P-384's elliptic curve group (i.e. scalar modulus).
    const ORDER: Odd<U384> = Odd::<U384>::from_be_hex(ORDER_HEX);
}

impl elliptic_curve::PrimeCurve for NistP384 {}

impl elliptic_curve::point::PointCompression for NistP384 {
    /// NIST P-384 points are typically uncompressed.
    const COMPRESS_POINTS: bool = false;
}

impl elliptic_curve::point::PointCompaction for NistP384 {
    /// NIST P-384 points are typically uncompressed.
    const COMPACT_POINTS: bool = false;
}

#[cfg(feature = "pkcs8")]
impl pkcs8::AssociatedOid for NistP384 {
    const OID: pkcs8::ObjectIdentifier = pkcs8::ObjectIdentifier::new_unwrap("1.3.132.0.34");
}

/// Compressed SEC1-encoded NIST P-384 curve point.
pub type CompressedPoint = Array<u8, U49>;

/// NIST P-384 SEC1 encoded point.
pub type EncodedPoint = elliptic_curve::sec1::EncodedPoint<NistP384>;

/// NIST P-384 field element serialized as bytes.
///
/// Byte array containing a serialized field element value (base field or
/// scalar).
pub type FieldBytes = elliptic_curve::FieldBytes<NistP384>;

impl FieldBytesEncoding<NistP384> for U384 {
    fn decode_field_bytes(field_bytes: &FieldBytes) -> Self {
        U384::from_be_byte_array(*field_bytes)
    }

    fn encode_field_bytes(&self) -> FieldBytes {
        self.to_be_byte_array()
    }
}

/// Non-zero NIST P-384 scalar field element.
#[cfg(feature = "arithmetic")]
pub type NonZeroScalar = elliptic_curve::NonZeroScalar<NistP384>;

/// NIST P-384 public key.
#[cfg(feature = "arithmetic")]
pub type PublicKey = elliptic_curve::PublicKey<NistP384>;

/// NIST P-384 secret key.
pub type SecretKey = elliptic_curve::SecretKey<NistP384>;

#[cfg(not(feature = "arithmetic"))]
impl elliptic_curve::sec1::ValidatePublicKey for NistP384 {}

/// Bit representation of a NIST P-384 scalar field element.
#[cfg(feature = "bits")]
pub type ScalarBits = elliptic_curve::scalar::ScalarBits<NistP384>;

#[cfg(feature = "oprf")]
impl hash2curve::OprfParameters for NistP384 {
    /// See <https://www.rfc-editor.org/rfc/rfc9497.html#section-4.4-1>.
    const ID: &'static [u8] = b"P384-SHA384";
}
