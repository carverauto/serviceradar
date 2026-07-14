#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg"
)]
#![forbid(unsafe_code)]
#![warn(missing_docs, rust_2018_idioms, unused_qualifications)]
#![doc = include_str!("../README.md")]

mod dev;
mod macros;
mod monty;

pub use crate::monty::{MontyFieldBytes, MontyFieldElement, MontyFieldParams, compute_t};
pub use array::typenum::consts;
pub use bigint;
pub use bigint::hybrid_array as array;
pub use ff;
pub use rand_core;
pub use subtle;
pub use zeroize;

/// Byte order used when encoding/decoding field elements as bytestrings.
#[derive(Debug)]
pub enum ByteOrder {
    /// Big endian.
    BigEndian,

    /// Little endian.
    LittleEndian,
}
