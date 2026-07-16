use hybrid_array::{
    sizes::{U0, U1, U256},
    typenum::{IsLess, NonZero, True, Unsigned},
};

use super::{Array, ArraySize};
use core::{mem::MaybeUninit, ptr};

type Block<N> = MaybeUninit<Array<u8, N>>;

/// Sealed trait for buffer kinds.
pub trait Sealed {
    #[cfg(not(feature = "zeroize"))]
    type Pos: Default + Clone;
    #[cfg(feature = "zeroize")]
    type Pos: Default + Clone + zeroize::Zeroize;

    type Overhead: ArraySize;

    const NAME: &'static str;

    fn get_pos<N: ArraySize>(buf: &Block<N>, pos: &Self::Pos) -> usize;

    fn set_pos<N: ArraySize>(buf: &mut Block<N>, pos: &mut Self::Pos, val: usize);

    /// Invariant guaranteed by a buffer kind, i.e. with correct
    /// buffer code this function always returns true.
    fn invariant(pos: usize, block_size: usize) -> bool;

    /// Split input data into slice of blocks and tail.
    fn split_blocks<N: ArraySize>(data: &[u8]) -> (&[Array<u8, N>], &[u8]);
}

impl Sealed for super::Eager {
    type Pos = ();
    type Overhead = U0;
    const NAME: &'static str = "BlockBuffer<Eager>";

    fn get_pos<N: ArraySize>(buf: &Block<N>, _pos: &Self::Pos) -> usize {
        // SAFETY: last byte in `buf` for eager hashes is always properly initialized
        let pos = unsafe {
            let buf_ptr = buf.as_ptr().cast::<u8>();
            let last_byte_ptr = buf_ptr.add(N::USIZE - 1);
            ptr::read(last_byte_ptr)
        };
        pos as usize
    }

    #[allow(clippy::cast_possible_truncation)]
    fn set_pos<N: ArraySize>(buf: &mut Block<N>, _pos: &mut Self::Pos, val: usize) {
        debug_assert!(u8::try_from(val).is_ok());
        // SAFETY: we write to the last byte of `buf` which is always safe
        unsafe {
            let buf_ptr = buf.as_mut_ptr().cast::<u8>();
            let last_byte_ptr = buf_ptr.add(N::USIZE - 1);
            ptr::write(last_byte_ptr, val as u8);
        }
    }

    #[inline(always)]
    fn invariant(pos: usize, block_size: usize) -> bool {
        pos < block_size
    }

    #[inline(always)]
    fn split_blocks<N: ArraySize>(data: &[u8]) -> (&[Array<u8, N>], &[u8]) {
        Array::slice_as_chunks(data)
    }
}

impl Sealed for super::Lazy {
    type Pos = u8;
    type Overhead = U1;
    const NAME: &'static str = "BlockBuffer<Lazy>";

    fn get_pos<N: ArraySize>(_buf_val: &Block<N>, pos: &Self::Pos) -> usize {
        *pos as usize
    }

    #[allow(clippy::cast_possible_truncation)]
    fn set_pos<N: ArraySize>(_: &mut Block<N>, pos: &mut Self::Pos, val: usize) {
        debug_assert!(u8::try_from(val).is_ok());
        *pos = val as u8;
    }

    #[inline(always)]
    fn invariant(pos: usize, block_size: usize) -> bool {
        pos <= block_size
    }

    #[inline(always)]
    fn split_blocks<N: ArraySize>(data: &[u8]) -> (&[Array<u8, N>], &[u8]) {
        let (blocks, tail) = Array::slice_as_chunks(data);
        if data.is_empty() || !tail.is_empty() {
            (blocks, tail)
        } else {
            let (tail, blocks) = blocks.split_last().expect("`blocks` can not be empty");
            (blocks, tail)
        }
    }
}

/// Sealed trait implemented for sizes from `U1` to `U255`.
pub trait BlockSizes {}

impl<T: Unsigned> BlockSizes for T where Self: IsLess<U256, Output = True> + NonZero {}
