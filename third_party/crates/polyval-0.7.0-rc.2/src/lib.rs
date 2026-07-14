#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]
#![warn(missing_docs)]

mod backend;
mod mulx;

pub use crate::{backend::Polyval, backend::PolyvalGeneric, mulx::mulx};
pub use universal_hash;

impl<const N: usize> core::fmt::Debug for PolyvalGeneric<N> {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> Result<(), core::fmt::Error> {
        write!(f, "PolyvalGeneric<{}> {{ ... }}", N)
    }
}

/// Size of a POLYVAL block in bytes
pub const BLOCK_SIZE: usize = 16;

/// Size of a POLYVAL key in bytes
pub const KEY_SIZE: usize = 16;

/// POLYVAL keys (16-bytes)
pub type Key = universal_hash::Key<Polyval>;

/// POLYVAL blocks (16-bytes)
pub type Block = universal_hash::Block<Polyval>;

/// POLYVAL tags (16-bytes)
pub type Tag = universal_hash::Block<Polyval>;
