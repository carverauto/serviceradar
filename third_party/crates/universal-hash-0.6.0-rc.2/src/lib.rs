#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]
#![forbid(unsafe_code)]
#![warn(missing_docs, rust_2018_idioms, missing_debug_implementations)]

pub use crypto_common::{
    self, Block, Key, KeyInit, ParBlocks, Reset, array,
    typenum::{self, consts},
};

use core::slice;
use crypto_common::{BlockSizeUser, BlockSizes, ParBlocksSizeUser, array::Array};
use subtle::ConstantTimeEq;
use typenum::Unsigned;

/// Trait implemented by UHF backends.
pub trait UhfBackend: ParBlocksSizeUser {
    /// Process single block.
    fn proc_block(&mut self, block: &Block<Self>);

    /// Process several blocks in parallel.
    #[inline(always)]
    fn proc_par_blocks(&mut self, blocks: &ParBlocks<Self>) {
        for block in blocks {
            self.proc_block(block);
        }
    }

    /// Returns the number of blocks that should be passed to `Self::proc_block` before
    /// `Self::proc_par_blocks` can be used efficiently. This is always less than
    /// `Self::ParBlocksSize`.
    fn blocks_needed_to_align(&self) -> usize {
        0
    }
}

/// Trait for [`UhfBackend`] users.
///
/// This trait is used to define rank-2 closures.
pub trait UhfClosure: BlockSizeUser {
    /// Execute closure with the provided UHF backend.
    fn call<B: UhfBackend<BlockSize = Self::BlockSize>>(self, backend: &mut B);
}

/// The [`UniversalHash`] trait defines a generic interface for universal hash
/// functions.
pub trait UniversalHash: BlockSizeUser + Sized {
    /// Update hash function state using the provided rank-2 closure.
    fn update_with_backend(&mut self, f: impl UhfClosure<BlockSize = Self::BlockSize>);

    /// Update hash function state with the provided block.
    #[inline]
    fn update(&mut self, blocks: &[Block<Self>]) {
        struct Ctx<'a, BS: BlockSizes> {
            blocks: &'a [Block<Self>],
        }

        impl<BS: BlockSizes> BlockSizeUser for Ctx<'_, BS> {
            type BlockSize = BS;
        }

        impl<BS: BlockSizes> UhfClosure for Ctx<'_, BS> {
            #[inline(always)]
            fn call<B: UhfBackend<BlockSize = BS>>(self, backend: &mut B) {
                let pb = B::ParBlocksSize::USIZE;
                if pb > 1 {
                    let (par_blocks, tail) = Array::slice_as_chunks(self.blocks);
                    for par_block in par_blocks {
                        backend.proc_par_blocks(par_block);
                    }
                    for block in tail {
                        backend.proc_block(block);
                    }
                } else {
                    for block in self.blocks {
                        backend.proc_block(block);
                    }
                }
            }
        }

        self.update_with_backend(Ctx { blocks });
    }

    /// Input data into the universal hash function. If the length of the
    /// data is not a multiple of the block size, the remaining data is
    /// padded with zeroes up to the `BlockSize`.
    ///
    /// This approach is frequently used by AEAD modes which use
    /// Message Authentication Codes (MACs) based on universal hashing.
    #[inline]
    fn update_padded(&mut self, data: &[u8]) {
        let (blocks, tail) = Array::slice_as_chunks(data);

        self.update(blocks);

        if !tail.is_empty() {
            let mut padded_block = Array::default();
            padded_block[..tail.len()].copy_from_slice(tail);
            self.update(slice::from_ref(&padded_block));
        }
    }

    /// Retrieve result and consume hasher instance.
    fn finalize(self) -> Block<Self>;

    /// Obtain the output of a [`UniversalHash`] computation and reset it back
    /// to its initial state.
    #[inline]
    fn finalize_reset(&mut self) -> Block<Self>
    where
        Self: Clone + Reset,
    {
        let ret = self.clone().finalize();
        self.reset();
        ret
    }

    /// Verify the [`UniversalHash`] of the processed input matches
    /// a given `expected` value.
    ///
    /// This is useful when constructing Message Authentication Codes (MACs)
    /// from universal hash functions.
    #[inline]
    fn verify(self, expected: &Block<Self>) -> Result<(), Error> {
        if self.finalize().ct_eq(expected).into() {
            Ok(())
        } else {
            Err(Error)
        }
    }
}

/// Error type used by the [`UniversalHash::verify`] method
/// to indicate that UHF output is not equal the expected value.
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct Error;

impl core::fmt::Display for Error {
    #[inline]
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("UHF output mismatch")
    }
}

impl core::error::Error for Error {}
