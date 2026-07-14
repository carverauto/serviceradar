//! Traits which define functionality of stream ciphers.
//!
//! See [RustCrypto/stream-ciphers](https://github.com/RustCrypto/stream-ciphers)
//! for ciphers implementation.

use crate::block::{BlockModeDecrypt, BlockModeEncrypt};
use crypto_common::Block;
use inout::{InOutBuf, NotEqualError};

mod core_api;
mod errors;
#[cfg(feature = "stream-wrapper")]
mod wrapper;

pub use core_api::{
    StreamCipherBackend, StreamCipherClosure, StreamCipherCore, StreamCipherCounter,
    StreamCipherSeekCore,
};
pub use errors::{OverflowError, StreamCipherError};
#[cfg(feature = "stream-wrapper")]
pub use wrapper::StreamCipherCoreWrapper;

/// Marker trait for block-level asynchronous stream ciphers
pub trait AsyncStreamCipher: Sized {
    /// Encrypt data using `InOutBuf`.
    fn encrypt_inout(mut self, data: InOutBuf<'_, '_, u8>)
    where
        Self: BlockModeEncrypt,
    {
        let (blocks, mut tail) = data.into_chunks();
        self.encrypt_blocks_inout(blocks);
        let n = tail.len();
        if n != 0 {
            let mut block = Block::<Self>::default();
            block[..n].copy_from_slice(tail.get_in());
            self.encrypt_block(&mut block);
            tail.get_out().copy_from_slice(&block[..n]);
        }
    }

    /// Decrypt data using `InOutBuf`.
    fn decrypt_inout(mut self, data: InOutBuf<'_, '_, u8>)
    where
        Self: BlockModeDecrypt,
    {
        let (blocks, mut tail) = data.into_chunks();
        self.decrypt_blocks_inout(blocks);
        let n = tail.len();
        if n != 0 {
            let mut block = Block::<Self>::default();
            block[..n].copy_from_slice(tail.get_in());
            self.decrypt_block(&mut block);
            tail.get_out().copy_from_slice(&block[..n]);
        }
    }
    /// Encrypt data in place.
    fn encrypt(self, buf: &mut [u8])
    where
        Self: BlockModeEncrypt,
    {
        self.encrypt_inout(buf.into());
    }

    /// Decrypt data in place.
    fn decrypt(self, buf: &mut [u8])
    where
        Self: BlockModeDecrypt,
    {
        self.decrypt_inout(buf.into());
    }

    /// Encrypt data from buffer to buffer.
    fn encrypt_b2b(self, in_buf: &[u8], out_buf: &mut [u8]) -> Result<(), NotEqualError>
    where
        Self: BlockModeEncrypt,
    {
        InOutBuf::new(in_buf, out_buf).map(|b| self.encrypt_inout(b))
    }

    /// Decrypt data from buffer to buffer.
    fn decrypt_b2b(self, in_buf: &[u8], out_buf: &mut [u8]) -> Result<(), NotEqualError>
    where
        Self: BlockModeDecrypt,
    {
        InOutBuf::new(in_buf, out_buf).map(|b| self.decrypt_inout(b))
    }
}

/// Synchronous stream cipher core trait.
pub trait StreamCipher {
    /// Apply keystream to `inout` data.
    ///
    /// If end of the keystream will be achieved with the given data length,
    /// method will return [`StreamCipherError`] without modifying provided `data`.
    fn try_apply_keystream_inout(
        &mut self,
        buf: InOutBuf<'_, '_, u8>,
    ) -> Result<(), StreamCipherError>;

    /// Apply keystream to data behind `buf`.
    ///
    /// If end of the keystream will be achieved with the given data length,
    /// method will return [`StreamCipherError`] without modifying provided `data`.
    #[inline]
    fn try_apply_keystream(&mut self, buf: &mut [u8]) -> Result<(), StreamCipherError> {
        self.try_apply_keystream_inout(buf.into())
    }

    /// Write keystream to `buf`.
    ///
    /// If end of the keystream will be achieved with the given data length,
    /// method will return [`StreamCipherError`] without modifying provided `data`.
    #[inline]
    fn try_write_keystream(&mut self, buf: &mut [u8]) -> Result<(), StreamCipherError> {
        buf.fill(0);
        self.try_apply_keystream(buf)
    }

    /// Apply keystream to `inout` data.
    ///
    /// It will XOR generated keystream with the data behind `in` pointer
    /// and will write result to `out` pointer.
    ///
    /// # Panics
    /// If end of the keystream will be reached with the given data length,
    /// method will panic without modifying the provided `data`.
    #[inline]
    fn apply_keystream_inout(&mut self, buf: InOutBuf<'_, '_, u8>) {
        self.try_apply_keystream_inout(buf).unwrap();
    }

    /// Apply keystream to data in-place.
    ///
    /// It will XOR generated keystream with `data` and will write result
    /// to the same buffer.
    ///
    /// # Panics
    /// If end of the keystream will be reached with the given data length,
    /// method will panic without modifying the provided `data`.
    #[inline]
    fn apply_keystream(&mut self, buf: &mut [u8]) {
        self.try_apply_keystream(buf).unwrap();
    }

    /// Write keystream to `buf`.
    ///
    /// # Panics
    /// If end of the keystream will be reached with the given data length,
    /// method will panic without modifying the provided `data`.
    #[inline]
    fn write_keystream(&mut self, buf: &mut [u8]) {
        self.try_write_keystream(buf).unwrap();
    }

    /// Apply keystream to data buffer-to-buffer.
    ///
    /// It will XOR generated keystream with data from the `input` buffer
    /// and will write result to the `output` buffer.
    ///
    /// Returns [`StreamCipherError`] if provided `in_blocks` and `out_blocks`
    /// have different lengths or if end of the keystream will be reached with
    /// the given input data length.
    #[inline]
    fn apply_keystream_b2b(
        &mut self,
        input: &[u8],
        output: &mut [u8],
    ) -> Result<(), StreamCipherError> {
        InOutBuf::new(input, output)
            .map_err(|_| StreamCipherError)
            .and_then(|buf| self.try_apply_keystream_inout(buf))
    }
}

/// Trait for seekable stream ciphers.
///
/// Methods of this trait are generic over the [`SeekNum`] trait, which is
/// implemented for primitive numeric types, i.e.: `i32`, `u32`, `u64`,
/// `u128`, and `usize`.
pub trait StreamCipherSeek {
    /// Try to get current keystream position
    ///
    /// Returns [`OverflowError`] if position can not be represented by type `T`
    fn try_current_pos<T: SeekNum>(&self) -> Result<T, OverflowError>;

    /// Try to seek to the given position
    ///
    /// Returns [`StreamCipherError`] if provided position value is bigger than
    /// keystream length.
    fn try_seek<T: SeekNum>(&mut self, pos: T) -> Result<(), StreamCipherError>;

    /// Get current keystream position
    ///
    /// # Panics
    /// If position can not be represented by type `T`
    fn current_pos<T: SeekNum>(&self) -> T {
        self.try_current_pos().unwrap()
    }

    /// Seek to the given position
    ///
    /// # Panics
    /// If provided position value is bigger than keystream length
    fn seek<T: SeekNum>(&mut self, pos: T) {
        self.try_seek(pos).unwrap()
    }
}

impl<C: StreamCipher> StreamCipher for &mut C {
    #[inline]
    fn try_apply_keystream_inout(
        &mut self,
        buf: InOutBuf<'_, '_, u8>,
    ) -> Result<(), StreamCipherError> {
        C::try_apply_keystream_inout(self, buf)
    }
}

/// Trait implemented for numeric types which can be used with the
/// [`StreamCipherSeek`] trait.
///
/// This trait is implemented for `i32`, `u32`, `u64`, `u128`, and `usize`.
/// It is not intended to be implemented in third-party crates.
pub trait SeekNum: Sized {
    /// Try to get position for block number `block`, byte position inside
    /// block `byte`, and block size `bs`.
    fn from_block_byte<T: StreamCipherCounter>(
        block: T,
        byte: u8,
        bs: u8,
    ) -> Result<Self, OverflowError>;

    /// Try to get block number and bytes position for given block size `bs`.
    fn into_block_byte<T: StreamCipherCounter>(self, bs: u8) -> Result<(T, u8), OverflowError>;
}

macro_rules! impl_seek_num {
    {$($t:ty )*} => {
        $(
            impl SeekNum for $t {
                fn from_block_byte<T: StreamCipherCounter>(block: T, byte: u8, block_size: u8) -> Result<Self, OverflowError> {
                    debug_assert!(byte != 0);
                    let rem = block_size.checked_sub(byte).ok_or(OverflowError)?;
                    let block: Self = block.try_into().map_err(|_| OverflowError)?;
                    block
                        .checked_mul(block_size.into())
                        .and_then(|v| v.checked_sub(rem.into()))
                        .ok_or(OverflowError)
                }

                fn into_block_byte<T: StreamCipherCounter>(self, block_size: u8) -> Result<(T, u8), OverflowError> {
                    let bs: Self = block_size.into();
                    let byte = (self % bs) as u8;
                    let block = T::try_from(self / bs).map_err(|_| OverflowError)?;
                    Ok((block, byte))
                }
            }
        )*
    };
}

impl_seek_num! { i32 u32 u64 u128 usize }
