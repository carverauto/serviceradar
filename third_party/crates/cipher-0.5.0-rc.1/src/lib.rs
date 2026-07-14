//! This crate defines a set of traits which describe the functionality of
//! [block ciphers][1], [block modes][2], and [stream ciphers][3].
//!
//! [1]: https://en.wikipedia.org/wiki/Block_cipher
//! [2]: https://en.wikipedia.org/wiki/Block_cipher_mode_of_operation
//! [3]: https://en.wikipedia.org/wiki/Stream_cipher

#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![warn(
    missing_docs,
    rust_2018_idioms,
    unused_lifetimes,
    missing_debug_implementations
)]
#![forbid(unsafe_code)]

#[cfg(feature = "alloc")]
extern crate alloc;

#[cfg(feature = "dev")]
pub use blobby;
pub use crypto_common;
#[cfg(feature = "rand_core")]
pub use crypto_common::rand_core;
pub use inout;
#[cfg(feature = "block-padding")]
pub use inout::block_padding;
#[cfg(feature = "zeroize")]
pub use zeroize;

pub mod block;
#[cfg(feature = "dev")]
pub mod dev;
pub mod stream;
pub mod tweak;

pub use block::*;
pub use stream::*;
pub use tweak::*;

pub use crypto_common::{
    AlgorithmName, Block, BlockSizeUser, InnerIvInit, InvalidLength, Iv, IvSizeUser, IvState, Key,
    KeyInit, KeyIvInit, KeySizeUser, ParBlocks, ParBlocksSizeUser,
    array::{self, Array},
    typenum::{self, consts},
};
pub use inout::{InOut, InOutBuf};
