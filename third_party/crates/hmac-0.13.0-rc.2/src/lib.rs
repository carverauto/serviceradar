// Overwrite intra-crate links
//! [`Reset`]: digest::Reset
//! [`Digest`]: digest::Digest
//! [`FixedOutputReset`]: digest::FixedOutputReset
//! [`Hmac`]: Hmac
//! [`HmacReset`]: HmacReset
//! [`SimpleHmac`]: SimpleHmac
//! [`SimpleHmacReset`]: SimpleHmacReset
//! [`block_api::HmacCore`]: block_api::HmacCore
//! [`block_api::HmacResetCore`]: block_api::HmacResetCore

#![no_std]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/26acc39f/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/26acc39f/logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub use digest::{self, KeyInit, Mac, block_api::EagerHash};

/// Block-level implementation.
pub mod block_api;
mod simple;
mod simple_reset;
mod utils;

pub use simple::SimpleHmac;
pub use simple_reset::SimpleHmacReset;

use core::fmt;
use digest::block_api::{AlgorithmName, CoreProxy};

digest::buffer_fixed!(
    /// Generic HMAC instance.
    pub struct Hmac<D: EagerHash>(block_api::HmacCore<D>);
    impl: MacTraits KeyInit;
);

impl<D: EagerHash + AlgorithmName> AlgorithmName for Hmac<D> {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        <Self as CoreProxy>::Core::write_alg_name(f)
    }
}

digest::buffer_fixed!(
    /// Generic HMAC instance with reset support.
    pub struct HmacReset<D: EagerHash>(block_api::HmacResetCore<D>);
    impl: ResetMacTraits KeyInit;
);

impl<D: EagerHash + AlgorithmName> AlgorithmName for HmacReset<D> {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        <Self as CoreProxy>::Core::write_alg_name(f)
    }
}
