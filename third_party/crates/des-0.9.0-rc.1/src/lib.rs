//! Pure Rust implementation of the [Data Encryption Standard][DES] (DES),
//! including [Triple DES] (TDES, 3DES) block ciphers.
//!
//! # ⚠️ Security Warning: Hazmat!
//!
//! This crate implements only the low-level block cipher function, and is intended
//! for use for implementing higher-level constructions *only*. It is NOT
//! intended for direct use in applications.
//!
//! USE AT YOUR OWN RISK!
//!
//! [DES]: https://en.wikipedia.org/wiki/Data_Encryption_Standard
//! [Triple DES]: https://en.wikipedia.org/wiki/Triple_DES

#![no_std]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/26acc39f/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/26acc39f/logo.svg"
)]
#![deny(unsafe_code)]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![warn(missing_docs, rust_2018_idioms)]

pub use cipher;

mod consts;
mod des;
mod tdes;
mod utils;

pub use crate::des::Des;
pub use crate::tdes::{TdesEde2, TdesEde3, TdesEee2, TdesEee3};

/// Checks whether the key is weak.
///
/// Returns 1 if the key is weak; otherwise, returns 0.
fn weak_key_test(key: u64) -> u8 {
    let mut is_weak = 0u8;
    for &weak_key in crate::consts::WEAK_KEYS {
        is_weak |= u8::from(key == weak_key);
    }
    is_weak
}
