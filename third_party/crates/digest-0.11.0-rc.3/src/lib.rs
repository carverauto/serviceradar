//! This crate provides traits which describe functionality of cryptographic hash
//! functions and Message Authentication algorithms.
//!
//! Traits in this repository are organized into the following levels:
//!
//! - **High-level convenience traits**: [`Digest`], [`DynDigest`], [`Mac`].
//!   Wrappers around lower-level traits for most common use-cases. Users should
//!   usually prefer using these traits.
//! - **Mid-level traits**: [`Update`], [`FixedOutput`], [`FixedOutputReset`],
//!   [`ExtendableOutput`], [`ExtendableOutputReset`], [`XofReader`],
//!   [`VariableOutput`], [`Reset`], [`KeyInit`], and [`InnerInit`]. These
//!   traits atomically describe available functionality of an algorithm.
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

#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![forbid(unsafe_code)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![warn(missing_docs, rust_2018_idioms, missing_debug_implementations)]

#[cfg(feature = "alloc")]
#[macro_use]
extern crate alloc;

#[cfg(feature = "rand_core")]
pub use crypto_common::rand_core;

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
#[cfg(feature = "oid")]
pub use const_oid;
pub use crypto_common;

#[cfg(feature = "const-oid")]
pub use crate::digest::DynDigestWithOid;
pub use crate::digest::{Digest, DynDigest, HashMarker};
#[cfg(feature = "mac")]
pub use crypto_common::{InnerInit, InvalidLength, Key, KeyInit};
pub use crypto_common::{Output, OutputSizeUser, Reset, array, typenum, typenum::consts};
#[cfg(feature = "mac")]
pub use mac::{CtOutput, Mac, MacError, MacMarker};
pub use xof_fixed::XofFixedWrapper;

#[cfg(feature = "block-api")]
#[deprecated(
    since = "0.11.0",
    note = "`digest::core_api` has been replaced by `digest::block_api`"
)]
pub use block_api as core_api;

use core::fmt;
use crypto_common::typenum::Unsigned;

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

/// Trait for hash functions with variable-size output.
pub trait VariableOutput: Sized + Update {
    /// Maximum size of output hash in bytes.
    const MAX_OUTPUT_SIZE: usize;

    /// Create new hasher instance with the given output size in bytes.
    ///
    /// It will return `Err(InvalidOutputSize)` in case if hasher can not return
    /// hash of the specified output size.
    fn new(output_size: usize) -> Result<Self, InvalidOutputSize>;

    /// Get output size in bytes of the hasher instance provided to the `new` method
    fn output_size(&self) -> usize;

    /// Write result into the output buffer.
    ///
    /// Returns `Err(InvalidOutputSize)` if `out` size is not equal to
    /// `self.output_size()`.
    fn finalize_variable(self, out: &mut [u8]) -> Result<(), InvalidBufferSize>;

    /// Compute hash of `data` and write it to `output`.
    ///
    /// Length of the output hash is determined by `output`. If `output` is
    /// bigger than `Self::MAX_OUTPUT_SIZE`, this method returns
    /// `InvalidOutputSize`.
    fn digest_variable(
        input: impl AsRef<[u8]>,
        output: &mut [u8],
    ) -> Result<(), InvalidOutputSize> {
        let mut hasher = Self::new(output.len())?;
        hasher.update(input.as_ref());
        hasher
            .finalize_variable(output)
            .map_err(|_| InvalidOutputSize)
    }

    /// Retrieve result into a boxed slice and consume hasher.
    ///
    /// `Box<[u8]>` is used instead of `Vec<u8>` to save stack space, since
    /// they have size of 2 and 3 words respectively.
    #[cfg(feature = "alloc")]
    fn finalize_boxed(self) -> Box<[u8]> {
        let n = self.output_size();
        let mut buf = vec![0u8; n].into_boxed_slice();
        self.finalize_variable(&mut buf)
            .expect("buf length is equal to output_size");
        buf
    }
}

/// Trait for hash functions with variable-size output able to reset themselves.
pub trait VariableOutputReset: VariableOutput + Reset {
    /// Write result into the output buffer and reset the hasher state.
    ///
    /// Returns `Err(InvalidOutputSize)` if `out` size is not equal to
    /// `self.output_size()`.
    fn finalize_variable_reset(&mut self, out: &mut [u8]) -> Result<(), InvalidBufferSize>;

    /// Retrieve result into a boxed slice and reset the hasher state.
    ///
    /// `Box<[u8]>` is used instead of `Vec<u8>` to save stack space, since
    /// they have size of 2 and 3 words respectively.
    #[cfg(feature = "alloc")]
    fn finalize_boxed_reset(&mut self) -> Box<[u8]> {
        let n = self.output_size();
        let mut buf = vec![0u8; n].into_boxed_slice();
        self.finalize_variable_reset(&mut buf)
            .expect("buf length is equal to output_size");
        buf
    }
}

/// Trait for hash functions with customization string for domain separation.
pub trait CustomizedInit: Sized {
    /// Create new hasher instance with the given customization string.
    fn new_customized(customization: &[u8]) -> Self;
}

/// Trait adding customization string to hash functions with variable output.
pub trait VarOutputCustomized: Sized {
    /// Create new hasher instance with the given customization string and output size.
    fn new_customized(customization: &[u8], output_size: usize) -> Self;
}

/// Types with a certain collision resistance.
pub trait CollisionResistance {
    /// Collision resistance in bytes. This applies to an output size of `CollisionResistance * 2`.
    /// The collision resistance with a smaller output size is not defined by this trait and is at
    /// least the given collision resistance with a bigger output.
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
