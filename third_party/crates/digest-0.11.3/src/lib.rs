#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc = include_str!("../README.md")]
#![forbid(unsafe_code)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![allow(clippy::unwrap_used)] // TODO

//! ## Structure
//!
//! Traits in this crate are organized into the following levels:
//!
//! - **High-level convenience traits**: [`Digest`], [`DynDigest`], [`Mac`].
//!   Wrappers around lower-level traits for most common use-cases. Users should
//!   usually prefer using these traits.
//! - **Mid-level traits**: [`Update`], [`FixedOutput`], [`FixedOutputReset`], [`ExtendableOutput`],
//!   [`ExtendableOutputReset`], [`XofReader`], [`Reset`], [`KeyInit`], and [`InnerInit`].
//!   These traits atomically describe available functionality of an algorithm.
//! - **Marker traits**: [`HashMarker`], [`MacMarker`]. Used to distinguish
//!   different algorithm classes.
//! - **Low-level traits** defined in the [`block_api`] module. These traits
//!   operate at a block-level and do not contain any built-in buffering.
//!   They are intended to be implemented by low-level algorithm providers only.
//!   Usually they should not be used in application-level code.
//!
//! Additionally hash functions implement traits from the standard library:
//! [`Default`] and [`Clone`].
//!
//! This crate does not provide any implementations of the `io::Read/Write` traits,
//! see the [`digest-io`] crate for `std::io`-compatibility wrappers.
//!
//! [`digest-io`]: https://docs.rs/digest-io

#[cfg(feature = "alloc")]
#[macro_use]
extern crate alloc;

#[cfg(feature = "rand_core")]
pub use common::rand_core;

#[cfg(feature = "zeroize")]
pub use zeroize;

#[cfg(feature = "alloc")]
use alloc::boxed::Box;

#[cfg(feature = "dev")]
pub mod dev;

#[cfg(feature = "block-api")]
pub mod block_api;
mod buffer_macros;
mod digest;
#[cfg(feature = "mac")]
mod mac;
mod xof_fixed;

#[cfg(feature = "block-api")]
pub use block_buffer;
pub use common;
#[cfg(feature = "oid")]
pub use const_oid;

#[cfg(feature = "oid")]
pub use crate::digest::DynDigestWithOid;
pub use crate::digest::{Digest, DynDigest, HashMarker};
#[cfg(feature = "mac")]
pub use common::{InnerInit, InvalidLength, Key, KeyInit};
pub use common::{Output, OutputSizeUser, Reset, array, typenum, typenum::consts};
#[cfg(feature = "mac")]
pub use mac::{CtOutput, Mac, MacError, MacMarker};
pub use xof_fixed::XofFixedWrapper;

use common::typenum::Unsigned;
use core::fmt;

/// Types which consume data with byte granularity.
pub trait Update {
    /// Update state using the provided data.
    fn update(&mut self, data: &[u8]);

    /// Digest input data in a chained manner.
    #[must_use]
    fn chain(mut self, data: impl AsRef<[u8]>) -> Self
    where
        Self: Sized,
    {
        self.update(data.as_ref());
        self
    }
}

/// Trait for hash functions with fixed-size output.
pub trait FixedOutput: Update + OutputSizeUser + Sized {
    /// Consume value and write result into provided array.
    fn finalize_into(self, out: &mut Output<Self>);

    /// Retrieve result and consume the hasher instance.
    #[inline]
    fn finalize_fixed(self) -> Output<Self> {
        let mut out = Default::default();
        self.finalize_into(&mut out);
        out
    }
}

/// Trait for hash functions with fixed-size output able to reset themselves.
pub trait FixedOutputReset: FixedOutput + Reset {
    /// Write result into provided array and reset the hasher state.
    fn finalize_into_reset(&mut self, out: &mut Output<Self>);

    /// Retrieve result and reset the hasher state.
    #[inline]
    fn finalize_fixed_reset(&mut self) -> Output<Self> {
        let mut out = Default::default();
        self.finalize_into_reset(&mut out);
        out
    }
}

/// Trait for reader types which are used to extract extendable output
/// from a XOF (extendable-output function) result.
pub trait XofReader {
    /// Read output into the `buffer`. Can be called an unlimited number of times.
    fn read(&mut self, buffer: &mut [u8]);

    /// Read output into a boxed slice of the specified size.
    ///
    /// Can be called an unlimited number of times in combination with `read`.
    ///
    /// `Box<[u8]>` is used instead of `Vec<u8>` to save stack space, since
    /// they have size of 2 and 3 words respectively.
    #[cfg(feature = "alloc")]
    fn read_boxed(&mut self, n: usize) -> Box<[u8]> {
        let mut buf = vec![0u8; n].into_boxed_slice();
        self.read(&mut buf);
        buf
    }
}

/// Trait for hash functions with extendable-output (XOF).
pub trait ExtendableOutput: Sized + Update {
    /// Reader
    type Reader: XofReader;

    /// Retrieve XOF reader and consume hasher instance.
    fn finalize_xof(self) -> Self::Reader;

    /// Finalize XOF and write result into `out`.
    fn finalize_xof_into(self, out: &mut [u8]) {
        self.finalize_xof().read(out);
    }

    /// Compute hash of `data` and write it into `output`.
    fn digest_xof(input: impl AsRef<[u8]>, output: &mut [u8])
    where
        Self: Default,
    {
        let mut hasher = Self::default();
        hasher.update(input.as_ref());
        hasher.finalize_xof().read(output);
    }

    /// Retrieve result into a boxed slice of the specified size and consume
    /// the hasher.
    ///
    /// `Box<[u8]>` is used instead of `Vec<u8>` to save stack space, since
    /// they have size of 2 and 3 words respectively.
    #[cfg(feature = "alloc")]
    fn finalize_boxed(self, output_size: usize) -> Box<[u8]> {
        let mut buf = vec![0u8; output_size].into_boxed_slice();
        self.finalize_xof().read(&mut buf);
        buf
    }
}

/// Trait for hash functions with extendable-output (XOF) able to reset themselves.
pub trait ExtendableOutputReset: ExtendableOutput + Reset {
    /// Retrieve XOF reader and reset hasher instance state.
    fn finalize_xof_reset(&mut self) -> Self::Reader;

    /// Finalize XOF, write result into `out`, and reset the hasher state.
    fn finalize_xof_reset_into(&mut self, out: &mut [u8]) {
        self.finalize_xof_reset().read(out);
    }

    /// Retrieve result into a boxed slice of the specified size and reset
    /// the hasher state.
    ///
    /// `Box<[u8]>` is used instead of `Vec<u8>` to save stack space, since
    /// they have size of 2 and 3 words respectively.
    #[cfg(feature = "alloc")]
    fn finalize_boxed_reset(&mut self, output_size: usize) -> Box<[u8]> {
        let mut buf = vec![0u8; output_size].into_boxed_slice();
        self.finalize_xof_reset().read(&mut buf);
        buf
    }
}

/// Trait for hash functions with customization string for domain separation.
pub trait CustomizedInit: Sized {
    /// Create new hasher instance with the given customization string.
    fn new_customized(customization: &[u8]) -> Self;
}

/// Trait for hash functions with customization string for domain separation which place
/// restrictions on customization strings.
pub trait TryCustomizedInit: Sized {
    /// Error returned for invalid customization strings.
    type Error;

    /// Create new hasher instance with the given customization string.
    ///
    /// # Errors
    /// If the provided customization string is not valid for the hash function.
    fn try_new_customized(customization: &[u8]) -> Result<Self, Self::Error>;
}

impl<T: CustomizedInit> TryCustomizedInit for T {
    type Error = core::convert::Infallible;

    fn try_new_customized(customization: &[u8]) -> Result<Self, Self::Error> {
        Ok(Self::new_customized(customization))
    }
}

/// Types with a certain collision resistance.
pub trait CollisionResistance {
    /// Collision resistance in bytes.
    ///
    /// This applies to an output size of at least `2 * CollisionResistance` bytes.
    /// For a smaller output size collision resistance can be usually calculated as
    /// `min(CollisionResistance, OutputSize / 2)`.
    type CollisionResistance: Unsigned;
}

/// The error type used in variable hash traits.
#[derive(Clone, Copy, Debug, Default)]
pub struct InvalidOutputSize;

impl fmt::Display for InvalidOutputSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid output size")
    }
}

impl core::error::Error for InvalidOutputSize {}

/// Buffer length is not equal to hash output size.
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct InvalidBufferSize;

impl fmt::Display for InvalidBufferSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid buffer length")
    }
}

impl core::error::Error for InvalidBufferSize {}
