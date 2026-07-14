use crate::{InOutBuf, errors::OutIsTooSmallError};
use core::{marker::PhantomData, slice};

#[cfg(feature = "block-padding")]
use {
    crate::{InOut, errors::PadError},
    block_padding::{PadType, Padding},
    hybrid_array::{Array, ArraySize},
};

/// Custom slice type which references one immutable (input) slice and one
/// mutable (output) slice. Input and output slices are either the same or
/// do not overlap. Length of the output slice is always equal or bigger than
/// length of the input slice.
pub struct InOutBufReserved<'inp, 'out, T> {
    in_ptr: *const T,
    out_ptr: *mut T,
    in_len: usize,
    out_len: usize,
    _pd: PhantomData<(&'inp T, &'out mut T)>,
}

impl<'a, T> InOutBufReserved<'a, 'a, T> {
    /// Crate [`InOutBufReserved`] from a single mutable slice.
    pub fn from_mut_slice(buf: &'a mut [T], msg_len: usize) -> Result<Self, OutIsTooSmallError> {
        if msg_len > buf.len() {
            return Err(OutIsTooSmallError);
        }
        let p = buf.as_mut_ptr();
        let out_len = buf.len();
        Ok(Self {
            in_ptr: p,
            out_ptr: p,
            in_len: msg_len,
            out_len,
            _pd: PhantomData,
        })
    }
}

impl<T> InOutBufReserved<'_, '_, T> {
    /// Create [`InOutBufReserved`] from raw input and output pointers.
    ///
    /// # Safety
    /// Behavior is undefined if any of the following conditions are violated:
    /// - `in_ptr` must point to a properly initialized value of type `T` and
    ///   must be valid for reads for `in_len * mem::size_of::<T>()` many bytes.
    /// - `out_ptr` must point to a properly initialized value of type `T` and
    ///   must be valid for both reads and writes for `out_len * mem::size_of::<T>()`
    ///   many bytes.
    /// - `in_ptr` and `out_ptr` must be either equal or non-overlapping.
    /// - If `in_ptr` and `out_ptr` are equal, then the memory referenced by
    ///   them must not be accessed through any other pointer (not derived from
    ///   the return value) for the duration of lifetime 'a. Both read and write
    ///   accesses are forbidden.
    /// - If `in_ptr` and `out_ptr` are not equal, then the memory referenced by
    ///   `out_ptr` must not be accessed through any other pointer (not derived from
    ///   the return value) for the duration of lifetime 'a. Both read and write
    ///   accesses are forbidden. The memory referenced by `in_ptr` must not be
    ///   mutated for the duration of lifetime `'a`, except inside an `UnsafeCell`.
    /// - The total size `in_len * mem::size_of::<T>()` and
    ///   `out_len * mem::size_of::<T>()`  must be no larger than `isize::MAX`.
    #[inline(always)]
    pub unsafe fn from_raw(
        in_ptr: *const T,
        in_len: usize,
        out_ptr: *mut T,
        out_len: usize,
    ) -> Self {
        Self {
            in_ptr,
            out_ptr,
            in_len,
            out_len,
            _pd: PhantomData,
        }
    }

    /// Get raw input and output pointers.
    #[inline(always)]
    pub fn into_raw(self) -> (*const T, *mut T) {
        (self.in_ptr, self.out_ptr)
    }

    /// Get input buffer length.
    #[inline(always)]
    pub fn get_in_len(&self) -> usize {
        self.in_len
    }

    /// Get output buffer length.
    #[inline(always)]
    pub fn get_out_len(&self) -> usize {
        self.out_len
    }

    /// Split buffer into `InOutBuf` with input length and mutable slice pointing to
    /// the remaining reserved suffix.
    pub fn split_reserved(&mut self) -> (InOutBuf<'_, '_, T>, &mut [T]) {
        let in_len = self.get_in_len();
        let out_len = self.get_out_len();
        let in_ptr = self.get_in().as_ptr();
        let out_ptr = self.get_out().as_mut_ptr();
        // This never underflows because the type ensures that `out_len` is
        // bigger or equal to `in_len`.
        let tail_len = out_len - in_len;
        unsafe {
            let body = InOutBuf::from_raw(in_ptr, out_ptr, in_len);
            let tail = slice::from_raw_parts_mut(out_ptr.add(in_len), tail_len);
            (body, tail)
        }
    }
}

impl<'inp, 'out, T> InOutBufReserved<'inp, 'out, T> {
    /// Crate [`InOutBufReserved`] from two separate slices.
    pub fn from_slices(
        in_buf: &'inp [T],
        out_buf: &'out mut [T],
    ) -> Result<Self, OutIsTooSmallError> {
        if in_buf.len() > out_buf.len() {
            return Err(OutIsTooSmallError);
        }
        Ok(Self {
            in_ptr: in_buf.as_ptr(),
            out_ptr: out_buf.as_mut_ptr(),
            in_len: in_buf.len(),
            out_len: out_buf.len(),
            _pd: PhantomData,
        })
    }

    /// Get input slice.
    #[inline(always)]
    pub fn get_in(&self) -> &[T] {
        unsafe { slice::from_raw_parts(self.in_ptr, self.in_len) }
    }

    /// Get output slice.
    #[inline(always)]
    pub fn get_out(&mut self) -> &mut [T] {
        unsafe { slice::from_raw_parts_mut(self.out_ptr, self.out_len) }
    }

    /// Consume `self` and get output slice with lifetime `'out`.
    #[inline(always)]
    pub fn into_out(self) -> &'out mut [T] {
        unsafe { slice::from_raw_parts_mut(self.out_ptr, self.out_len) }
    }
}

#[cfg(feature = "block-padding")]
impl<'inp, 'out> InOutBufReserved<'inp, 'out, u8> {
    /// Transform buffer into [`PaddedInOutBuf`] using padding algorithm `P`.
    #[inline(always)]
    pub fn into_padded_blocks<P, BS>(self) -> Result<PaddedInOutBuf<'inp, 'out, BS>, PadError>
    where
        P: Padding<BS>,
        BS: ArraySize,
    {
        let bs = BS::USIZE;
        let blocks_len = self.in_len / bs;
        let tail_len = self.in_len - bs * blocks_len;
        let blocks = unsafe {
            InOutBuf::from_raw(
                self.in_ptr as *const Array<u8, BS>,
                self.out_ptr as *mut Array<u8, BS>,
                blocks_len,
            )
        };
        let mut tail_in = Array::<u8, BS>::default();
        let tail_out = match P::TYPE {
            PadType::NoPadding | PadType::Ambiguous if tail_len == 0 => None,
            PadType::NoPadding => return Err(PadError),
            PadType::Reversible | PadType::Ambiguous => {
                let blen = bs * blocks_len;
                let res_len = blen + bs;
                if res_len > self.out_len {
                    return Err(PadError);
                }
                // SAFETY: `in_ptr + blen..in_ptr + blen + tail_len`
                // is valid region for reads and `tail_len` is smaller than `BS`.
                // we have verified that `blen + bs <= out_len`, in other words,
                // `out_ptr + blen..out_ptr + blen + bs` is valid region
                // for writes.
                let out_block = unsafe {
                    core::ptr::copy_nonoverlapping(
                        self.in_ptr.add(blen),
                        tail_in.as_mut_ptr(),
                        tail_len,
                    );
                    &mut *(self.out_ptr.add(blen) as *mut Array<u8, BS>)
                };
                P::pad(&mut tail_in, tail_len);
                Some(out_block)
            }
        };
        Ok(PaddedInOutBuf {
            blocks,
            tail_in,
            tail_out,
        })
    }
}

/// Variant of [`InOutBuf`] with optional padded tail block.
#[cfg(feature = "block-padding")]
pub struct PaddedInOutBuf<'inp, 'out, BS: ArraySize> {
    blocks: InOutBuf<'inp, 'out, Array<u8, BS>>,
    tail_in: Array<u8, BS>,
    tail_out: Option<&'out mut Array<u8, BS>>,
}

#[cfg(feature = "block-padding")]
impl<'out, BS: ArraySize> PaddedInOutBuf<'_, 'out, BS> {
    /// Get full blocks.
    #[inline(always)]
    pub fn get_blocks(&mut self) -> InOutBuf<'_, '_, Array<u8, BS>> {
        self.blocks.reborrow()
    }

    /// Get padded tail block.
    ///
    /// For paddings with `P::TYPE = PadType::Reversible` it always returns `Some`.
    #[inline(always)]
    #[allow(clippy::needless_option_as_deref)]
    pub fn get_tail_block(&mut self) -> Option<InOut<'_, '_, Array<u8, BS>>> {
        match self.tail_out.as_deref_mut() {
            Some(out_block) => Some((&self.tail_in, out_block).into()),
            None => None,
        }
    }

    /// Convert buffer into output slice.
    #[inline(always)]
    pub fn into_out(self) -> &'out [u8] {
        let total_blocks = if self.tail_out.is_some() {
            self.blocks.len() + 1
        } else {
            self.blocks.len()
        };
        let res_len = BS::USIZE * total_blocks;
        let (_, out_ptr) = self.blocks.into_raw();
        // SAFETY: `res_len` is always valid for the output buffer since
        // it's checked during type construction
        unsafe { slice::from_raw_parts(out_ptr as *const u8, res_len) }
    }
}
