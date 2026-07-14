//! Fixed size buffer for block processing of data.
//!
//! # Examples
//! ```
//! use block_buffer::{EagerBuffer, array::typenum::U4};
//!
//! let mut buf = EagerBuffer::<U4>::default();
//!
//! let mut accum = Vec::new();
//! let msg1: &[u8] = &[0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
//! let msg2: &[u8] = &[10, 11, 12];
//!
//! buf.digest_blocks(msg1, |blocks| accum.extend_from_slice(blocks));
//! buf.digest_blocks(msg2, |blocks| accum.extend_from_slice(blocks));
//!
//! assert_eq!(accum.len(), 3);
//! assert_eq!(accum[0], [0, 1, 2, 3]);
//! assert_eq!(accum[1], [4, 5, 6, 7]);
//! assert_eq!(accum[2], [8, 9, 10, 11]);
//!
//! let padded_block = buf.pad_with_zeros();
//! assert_eq!(padded_block, [12, 0, 0, 0]);
//! ```
//!
//! Note that block size used with buffers MUST be bigger than zero and smaller than 256.
//! You will get a compilation error with an invalid block size:
//!
//! ```compile_fail
//! use block_buffer::{EagerBuffer, array::typenum::U0};
//! let buf = EagerBuffer::<U0>::default();
//! ```
//! ```compile_fail
//! use block_buffer::{EagerBuffer, array::typenum::U256};
//! let buf = EagerBuffer::<U256>::default();
//! ```
#![no_std]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![warn(missing_docs)]

pub use hybrid_array as array;

use array::{Array, ArraySize, typenum::Sum};
use core::{fmt, mem::MaybeUninit, ptr, slice};

#[cfg(feature = "zeroize")]
use zeroize::{Zeroize, ZeroizeOnDrop};

mod read;
mod sealed;

pub use read::ReadBuffer;

/// Trait for buffer kinds.
pub trait BufferKind: sealed::Sealed {}

/// Eager block buffer kind, which guarantees that buffer position
/// always lies in the range of `0..BlockSize`.
#[derive(Copy, Clone, Debug, Default)]
pub struct Eager {}

/// Lazy block buffer kind, which guarantees that buffer position
/// always lies in the range of `0..=BlockSize`.
#[derive(Copy, Clone, Debug, Default)]
pub struct Lazy {}

impl BufferKind for Eager {}

impl BufferKind for Lazy {}

/// Eager block buffer.
pub type EagerBuffer<B> = BlockBuffer<B, Eager>;
/// Lazy block buffer.
pub type LazyBuffer<B> = BlockBuffer<B, Lazy>;

/// Block buffer error.
#[derive(Copy, Clone, Eq, PartialEq, Debug)]
pub struct Error;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        f.write_str("Block buffer error")
    }
}

/// Buffer for block processing of data.
pub struct BlockBuffer<BS: ArraySize, K: BufferKind> {
    buffer: MaybeUninit<Array<u8, BS>>,
    pos: K::Pos,
}

impl<BS: ArraySize, K: BufferKind> BlockBuffer<BS, K> {
    /// This associated constant is used to assert block size correctness at compile time.
    const BLOCK_SIZE_ASSERT: bool = {
        if BS::USIZE == 0 {
            panic!("Block size can not be equal to zero!");
        }
        if BS::USIZE > 255 {
            panic!("Block size can not be bigger than 255!");
        }
        true
    };
}

impl<BS: ArraySize, K: BufferKind> Default for BlockBuffer<BS, K> {
    #[inline]
    fn default() -> Self {
        assert!(Self::BLOCK_SIZE_ASSERT);
        let mut buffer = MaybeUninit::uninit();
        let mut pos = Default::default();
        K::set_pos(&mut buffer, &mut pos, 0);
        Self { buffer, pos }
    }
}

impl<BS: ArraySize, K: BufferKind> Clone for BlockBuffer<BS, K> {
    #[inline]
    fn clone(&self) -> Self {
        // SAFETY: `BlockBuffer` does not implement `Drop` (i.e. it could be a `Copy` type),
        // so we can safely clone it using `ptr::read`.
        unsafe { ptr::read(self) }
    }
}

impl<BS: ArraySize, K: BufferKind> fmt::Debug for BlockBuffer<BS, K> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        f.debug_struct(K::NAME)
            .field("pos", &self.get_pos())
            .field("block_size", &BS::USIZE)
            .field("data", &self.get_data())
            .finish()
    }
}

impl<BS: ArraySize, K: BufferKind> BlockBuffer<BS, K> {
    /// Create new buffer from slice.
    ///
    /// # Panics
    /// If slice length is not valid for used buffer kind.
    #[inline(always)]
    pub fn new(buf: &[u8]) -> Self {
        Self::try_new(buf).unwrap()
    }

    /// Create new buffer from slice.
    ///
    /// Returns an error if slice length is not valid for used buffer kind.
    #[inline(always)]
    pub fn try_new(buf: &[u8]) -> Result<Self, Error> {
        assert!(Self::BLOCK_SIZE_ASSERT);
        if !K::invariant(buf.len(), BS::USIZE) {
            return Err(Error);
        }
        let mut res = Self::default();
        // SAFETY: we have checked that buffer length satisfies the buffer kind invariant
        unsafe {
            res.set_data_unchecked(buf);
        }
        Ok(res)
    }

    /// Digest data in `input` in blocks of size `BlockSize` using
    /// the `compress` function, which accepts slice of blocks.
    #[inline]
    pub fn digest_blocks(&mut self, mut input: &[u8], mut compress: impl FnMut(&[Array<u8, BS>])) {
        let pos = self.get_pos();
        // using `self.remaining()` for some reason
        // prevents panic elimination
        let rem = self.size() - pos;
        let n = input.len();
        // Note that checking condition `pos + n < BlockSize` is
        // equivalent to checking `n < rem`, where `rem` is equal
        // to `BlockSize - pos`. Using the latter allows us to work
        // around compiler accounting for possible overflow of
        // `pos + n` which results in it inserting unreachable
        // panic branches. Using `unreachable_unchecked` in `get_pos`
        // we convince compiler that `BlockSize - pos` never underflows.
        if K::invariant(n, rem) {
            // SAFETY: we have checked that length of `input` is smaller than
            // number of remaining bytes in `buffer`, so we can safely write data
            // into them and update cursor position.
            unsafe {
                let buf_ptr = self.buffer.as_mut_ptr().cast::<u8>().add(pos);
                ptr::copy_nonoverlapping(input.as_ptr(), buf_ptr, input.len());
                self.set_pos_unchecked(pos + input.len());
            }
            return;
        }
        if pos != 0 {
            let (left, right) = input.split_at(rem);
            input = right;
            // SAFETY: length of `left` is equal to number of remaining bytes in `buffer`,
            // so we can copy data into it and process `buffer` as fully initialized block.
            let block = unsafe {
                let buf_ptr = self.buffer.as_mut_ptr().cast::<u8>().add(pos);
                ptr::copy_nonoverlapping(left.as_ptr(), buf_ptr, left.len());
                self.buffer.assume_init_ref()
            };
            compress(slice::from_ref(block));
        }

        let (blocks, leftover) = K::split_blocks(input);
        if !blocks.is_empty() {
            compress(blocks);
        }

        // SAFETY: `leftover` is always smaller than block size,
        // so it satisfies the method's safety requirements for all buffer kinds
        unsafe {
            self.set_data_unchecked(leftover);
        }
    }

    /// Reset buffer by setting cursor position to zero.
    #[inline(always)]
    pub fn reset(&mut self) {
        // SAFETY: 0 is always valid position
        unsafe {
            self.set_pos_unchecked(0);
        }
    }

    /// Pad remaining data with zeros and return resulting block.
    #[inline(always)]
    pub fn pad_with_zeros(&mut self) -> Array<u8, BS> {
        let mut res = Array::<u8, BS>::default();
        let data = self.get_data();
        res[..data.len()].copy_from_slice(data);
        self.reset();
        res
    }

    /// Return current cursor position.
    #[inline(always)]
    pub fn get_pos(&self) -> usize {
        let pos = K::get_pos(&self.buffer, &self.pos);
        if !K::invariant(pos, BS::USIZE) {
            debug_assert!(false);
            // SAFETY: `pos` never breaks the invariant
            unsafe {
                core::hint::unreachable_unchecked();
            }
        }
        pos
    }

    /// Return slice of data stored inside the buffer.
    #[inline(always)]
    pub fn get_data(&self) -> &[u8] {
        // SAFETY: the `buffer` field is properly initialized up to `self.get_pos()`.
        // `get_pos` never returns position bigger than buffer size.
        unsafe { slice::from_raw_parts(self.buffer.as_ptr().cast(), self.get_pos()) }
    }

    /// Set buffer content and cursor position.
    ///
    /// # Panics
    /// If `pos` is bigger or equal to block size.
    #[inline]
    pub fn set(&mut self, buf: Array<u8, BS>, pos: usize) {
        assert!(K::invariant(pos, BS::USIZE));
        self.buffer = MaybeUninit::new(buf);
        // SAFETY: we have asserted that `pos` satisfies the invariant and
        // the `buffer` field is fully initialized
        unsafe {
            self.set_pos_unchecked(pos);
        }
    }

    /// Return size of the internal buffer in bytes.
    #[inline(always)]
    pub fn size(&self) -> usize {
        BS::USIZE
    }

    /// Return number of remaining bytes in the internal buffer.
    #[inline(always)]
    pub fn remaining(&self) -> usize {
        self.size() - self.get_pos()
    }

    /// Set buffer position.
    ///
    /// # Safety
    /// Bytes in the range of `0..pos` in the `buffer` field must be properly initialized.
    ///
    /// `pos` must satisfy invariant of buffer kind, i.e. for eager hashes it must be
    /// strictly smaller than block size and for lazy hashes it must be smaller or equal
    /// to block size.
    #[inline(always)]
    unsafe fn set_pos_unchecked(&mut self, pos: usize) {
        debug_assert!(K::invariant(pos, BS::USIZE));
        K::set_pos(&mut self.buffer, &mut self.pos, pos)
    }

    /// Set buffer data.
    ///
    /// # Safety
    /// Length of `buf` must satisfy invariant of buffer kind, i.e. for eager hashes it must be
    /// strictly smaller than block size and for lazy hashes it must be smaller or equal
    /// to block size.
    #[inline(always)]
    unsafe fn set_data_unchecked(&mut self, buf: &[u8]) {
        unsafe {
            self.set_pos_unchecked(buf.len());
            let dst_ptr: *mut u8 = self.buffer.as_mut_ptr().cast();
            ptr::copy_nonoverlapping(buf.as_ptr(), dst_ptr, buf.len());
        }
    }
}

/// Size of serialized `BlockBuffer` in bytes.
pub type SerializedBufferSize<BS, K> = Sum<BS, <K as sealed::Sealed>::Overhead>;
/// `BlockBuffer` serialized as a byte array.
pub type SerializedBuffer<BS, K> = Array<u8, SerializedBufferSize<BS, K>>;

impl<BS: ArraySize, K: BufferKind> BlockBuffer<BS, K>
where
    BS: core::ops::Add<K::Overhead>,
    Sum<BS, K::Overhead>: ArraySize,
{
    /// Serialize buffer into a byte array.
    pub fn serialize(&self) -> SerializedBuffer<BS, K> {
        let mut buf = SerializedBuffer::<BS, K>::default();
        let data = self.get_data();
        let (pos, block) = buf.split_at_mut(1);
        pos[0] = u8::try_from(data.len()).expect("buffer size is smaller than 256");
        block[..data.len()].copy_from_slice(data);
        buf
    }

    /// Deserialize buffer from a byte array.
    pub fn deserialize(buf: &SerializedBuffer<BS, K>) -> Result<Self, Error> {
        let (pos, block) = buf.split_at(1);
        let pos = usize::from(pos[0]);

        if !<K as sealed::Sealed>::invariant(pos, BS::USIZE) {
            return Err(Error);
        }

        let (data, tail) = block.split_at(pos);

        if tail.iter().any(|&b| b != 0) {
            return Err(Error);
        }

        let mut res = Self::default();
        unsafe { res.set_data_unchecked(data) };
        Ok(res)
    }
}

impl<BS: ArraySize> BlockBuffer<BS, Eager> {
    /// Compress remaining data after padding it with `delim`, zeros and
    /// the `suffix` bytes. If there is not enough unused space, `compress`
    /// will be called twice.
    ///
    /// # Panics
    /// If suffix length is bigger than block size.
    #[inline(always)]
    pub fn digest_pad(
        &mut self,
        delim: u8,
        suffix: &[u8],
        mut compress: impl FnMut(&Array<u8, BS>),
    ) {
        if suffix.len() > BS::USIZE {
            panic!("suffix is too long");
        }
        let pos = self.get_pos();
        let mut buf = self.pad_with_zeros();
        buf[pos] = delim;

        let n = self.size() - suffix.len();
        if self.size() - pos - 1 < suffix.len() {
            compress(&buf);
            buf.fill(0);
            buf[n..].copy_from_slice(suffix);
            compress(&buf);
        } else {
            buf[n..].copy_from_slice(suffix);
            compress(&buf);
        }
        self.reset();
    }

    /// Pad message with 0x80, zeros and 64-bit message length using
    /// big-endian byte order.
    #[inline]
    pub fn len64_padding_be(&mut self, data_len: u64, compress: impl FnMut(&Array<u8, BS>)) {
        self.digest_pad(0x80, &data_len.to_be_bytes(), compress);
    }

    /// Pad message with 0x80, zeros and 64-bit message length using
    /// little-endian byte order.
    #[inline]
    pub fn len64_padding_le(&mut self, data_len: u64, compress: impl FnMut(&Array<u8, BS>)) {
        self.digest_pad(0x80, &data_len.to_le_bytes(), compress);
    }

    /// Pad message with 0x80, zeros and 128-bit message length using
    /// big-endian byte order.
    #[inline]
    pub fn len128_padding_be(&mut self, data_len: u128, compress: impl FnMut(&Array<u8, BS>)) {
        self.digest_pad(0x80, &data_len.to_be_bytes(), compress);
    }
}

#[cfg(feature = "zeroize")]
impl<BS: ArraySize, K: BufferKind> Zeroize for BlockBuffer<BS, K> {
    #[inline]
    fn zeroize(&mut self) {
        self.buffer.zeroize();
        self.pos.zeroize();
    }
}

impl<BS: ArraySize, K: BufferKind> Drop for BlockBuffer<BS, K> {
    #[inline]
    fn drop(&mut self) {
        #[cfg(feature = "zeroize")]
        self.zeroize();
    }
}

#[cfg(feature = "zeroize")]
impl<BS: ArraySize, K: BufferKind> ZeroizeOnDrop for BlockBuffer<BS, K> {}
