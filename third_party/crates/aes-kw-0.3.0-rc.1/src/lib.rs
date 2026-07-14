#![no_std]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![forbid(unsafe_code)]
#![warn(missing_docs, rust_2018_idioms)]

#[cfg(feature = "oid")]
mod oid;

mod ctx;
mod error;
mod kw;
mod kwp;

use aes::cipher::consts::U8;
use aes::cipher::typenum::Unsigned;
pub use error::{Error, IntegrityCheckFailed};
pub use kw::AesKw;
pub use kwp::AesKwp;

pub use aes;
pub use aes::cipher;
pub use aes::cipher::{KeyInit, crypto_common::InnerInit};

/// AES-128 key wrapping
pub type KwAes128 = AesKw<aes::Aes128>;
/// AES-192 key wrapping
pub type KwAes192 = AesKw<aes::Aes192>;
/// AES-256 key wrapping
pub type KwAes256 = AesKw<aes::Aes256>;

/// AES-128 key wrapping
pub type KwpAes128 = AesKwp<aes::Aes128>;
/// AES-192 key wrapping
pub type KwpAes192 = AesKwp<aes::Aes192>;
/// AES-256 key wrapping
pub type KwpAes256 = AesKwp<aes::Aes256>;

/// Size of an AES-KW and AES-KWP initialization vector in bytes represented as a `typenum` type.
pub type IvLen = U8;
/// Size of an AES-KW and AES-KWP initialization vector in bytes.
///
/// This value is equal to "semiblock" size. From NIST SP 800-38F § 4.1:
///
/// > semiblock: given a block cipher, a bit string whose length is half of the block size.
pub const IV_LEN: usize = IvLen::USIZE;
