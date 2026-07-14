#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg"
)]
#![forbid(unsafe_code)]
#![warn(
    clippy::mod_module_files,
    clippy::unwrap_used,
    missing_docs,
    rust_2018_idioms,
    unused_lifetimes,
    unused_qualifications
)]

//! ## `serde` support
//!
//! When the `serde` feature of this crate is enabled, `Serialize` and
//! `Deserialize` are impl'd for the following types:
//!
//! - [`AffinePoint`]
//! - [`ProjectivePoint`]
//! - [`Scalar`]
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

#[cfg(feature = "arithmetic")]
pub use arithmetic::{AffinePoint, ProjectivePoint, scalar::Scalar};

#[cfg(feature = "expose-field")]
pub use arithmetic::field::FieldElement;

pub use elliptic_curve::{self, bigint::U576};

#[cfg(feature = "pkcs8")]
pub use elliptic_curve::pkcs8;

use elliptic_curve::{FieldBytesEncoding, array::Array, bigint::Odd, consts::U66};

/// NIST P-521 elliptic curve.
#[derive(Copy, Clone, Debug, Default, Eq, PartialEq, PartialOrd, Ord)]
pub struct NistP521;

const ORDER_HEX: &str = "00000000000001fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409";

impl elliptic_curve::Curve for NistP521 {
    /// 66-byte serialized field elements.
    type FieldBytesSize = U66;

    /// 521-bit integer type used for internally representing field elements.
    type Uint = U576;

    /// Order of NIST P-521's elliptic curve group (i.e. scalar modulus).
    const ORDER: Odd<U576> = Odd::<U576>::from_be_hex(ORDER_HEX);
}

impl elliptic_curve::PrimeCurve for NistP521 {}

impl elliptic_curve::point::PointCompression for NistP521 {
    /// NIST P-521 points are typically uncompressed.
    const COMPRESS_POINTS: bool = false;
}

impl elliptic_curve::point::PointCompaction for NistP521 {
    /// NIST P-521 points are typically uncompacted.
    const COMPACT_POINTS: bool = false;
}

#[cfg(feature = "pkcs8")]
impl pkcs8::AssociatedOid for NistP521 {
    const OID: pkcs8::ObjectIdentifier = pkcs8::ObjectIdentifier::new_unwrap("1.3.132.0.35");
}

/// Compressed SEC1-encoded NIST P-521 curve point.
pub type CompressedPoint = Array<u8, U66>;

/// NIST P-521 SEC1 encoded point.
pub type EncodedPoint = elliptic_curve::sec1::EncodedPoint<NistP521>;

/// NIST P-521 field element serialized as bytes.
///
/// Byte array containing a serialized field element value (base field or
/// scalar).
pub type FieldBytes = elliptic_curve::FieldBytes<NistP521>;

impl FieldBytesEncoding<NistP521> for U576 {}

/// Non-zero NIST P-521 scalar field element.
#[cfg(feature = "arithmetic")]
pub type NonZeroScalar = elliptic_curve::NonZeroScalar<NistP521>;

/// NIST P-521 public key.
#[cfg(feature = "arithmetic")]
pub type PublicKey = elliptic_curve::PublicKey<NistP521>;

/// NIST P-521 secret key.
pub type SecretKey = elliptic_curve::SecretKey<NistP521>;

#[cfg(feature = "oprf")]
impl hash2curve::OprfParameters for NistP521 {
    /// See <https://www.rfc-editor.org/rfc/rfc9497.html#section-4.5-1>.
    const ID: &'static [u8] = b"P521-SHA512";
}
