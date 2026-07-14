//! Collection of custom reference types for code generic over in-place and
//! buffer-to-buffer modes of operation.

#![no_std]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![warn(missing_docs)]

#[cfg(feature = "block-padding")]
pub use block_padding;

mod errors;
mod inout;
mod inout_buf;
mod reserved;

pub use crate::{errors::*, inout::*, inout_buf::*, reserved::*};
