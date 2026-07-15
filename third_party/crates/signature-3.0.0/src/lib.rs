#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]
#![forbid(unsafe_code)]
#![allow(async_fn_in_trait)]

//! # Design
//!
//! This crate provides a common set of traits for signing and verifying digital signatures intended
//! to be implemented by libraries which produce or contain implementations of digital signature
//! algorithms, and used by libraries which want to produce or verify digital signatures
//! generically.
//!
//! ## Unstable features
//!
//! Despite being post-1.0, this crate includes off-by-default unstable optional features, each of
//! which depends on a pre-1.0 crate.
//!
//! These features are considered exempt from SemVer. See "SemVer Policy Exemptions" for more
//! information.
//!
//! The following unstable features are presently supported:
//!
//! - `digest`: enables the [`DigestSigner`] and [`DigestVerifier`] traits which are based on the
//!   [`Digest`] trait from the [`digest`] crate.
//! - `rand_core`: enables the [`RandomizedSigner`] trait for signature systems which rely on a
//!   cryptographically secure random number generator for security.
//!
//! [`digest`]: https://docs.rs/digest/
//! [`Digest`]: https://docs.rs/digest/latest/digest/trait.Digest.html

#[cfg(feature = "alloc")]
extern crate alloc;

pub mod hazmat;

mod encoding;
mod error;
mod keypair;
mod signer;
mod verifier;

#[cfg(feature = "digest")]
pub use digest;

pub use crate::{encoding::*, error::*, keypair::*, signer::*, verifier::*};

#[cfg(feature = "rand_core")]
pub use rand_core;
