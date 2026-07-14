use super::{
    OverflowError, SeekNum, StreamCipher, StreamCipherCore, StreamCipherSeek, StreamCipherSeekCore,
    errors::StreamCipherError,
};
use block_buffer::ReadBuffer;
use core::fmt;
use crypto_common::{
    Iv, IvSizeUser, Key, KeyInit, KeyIvInit, KeySizeUser, array::Array, typenum::Unsigned,
};
use inout::InOutBuf;
#[cfg(feature = "zeroize")]
use zeroize::ZeroizeOnDrop;

/// Buffering wrapper around a [`StreamCipherCore`] implementation.
///
/// It handles data buffering and implements the slice-based traits.
pub struct StreamCipherCoreWrapper<T: StreamCipherCore> {
    core: T,
    buffer: ReadBuffer<T::BlockSize>,
}

impl<T: StreamCipherCore + Clone> Clone for StreamCipherCoreWrapper<T> {
    #[inline]
    fn clone(&self) -> Self {
        Self {
            core: self.core.clone(),
            buffer: self.buffer.clone(),
        }
    }
}

impl<T: StreamCipherCore + fmt::Debug> fmt::Debug for StreamCipherCoreWrapper<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StreamCipherCoreWrapper")
            .finish_non_exhaustive()
    }
}

impl<T: StreamCipherCore> StreamCipherCoreWrapper<T> {
    /// Initialize from a [`StreamCipherCore`] instance.
    pub fn from_core(core: T) -> Self {
        Self {
            core,
            buffer: Default::default(),
        }
    }

    fn check_remaining(&self, data_len: usize) -> Result<(), StreamCipherError> {
        let rem_blocks = match self.core.remaining_blocks() {
            Some(v) => v,
            None => return Ok(()),
        };

        let buf_rem = self.buffer.remaining();
        let data_len = match data_len.checked_sub(buf_rem) {
            Some(0) | None => return Ok(()),
            Some(res) => res,
        };

        let bs = T::BlockSize::USIZE;
        let blocks = data_len.div_ceil(bs);
        if blocks > rem_blocks {
            Err(StreamCipherError)
        } else {
            Ok(())
        }
    }
}

impl<T: StreamCipherCore> StreamCipher for StreamCipherCoreWrapper<T> {
    #[inline]
    fn try_apply_keystream_inout(
        &mut self,
        data: InOutBuf<'_, '_, u8>,
    ) -> Result<(), StreamCipherError> {
        self.check_remaining(data.len())?;

        let head_ks = self.buffer.read_cached(data.len());

        let (mut head, data) = data.split_at(head_ks.len());
        let (blocks, mut tail) = data.into_chunks();

        head.xor_in2out(head_ks);
        self.core.apply_keystream_blocks_inout(blocks);

        self.buffer.write_block(
            tail.len(),
            |b| self.core.write_keystream_block(b),
            |tail_ks| {
                tail.xor_in2out(tail_ks);
            },
        );

        Ok(())
    }

    #[inline]
    fn try_write_keystream(&mut self, data: &mut [u8]) -> Result<(), StreamCipherError> {
        self.check_remaining(data.len())?;

        let head_ks = self.buffer.read_cached(data.len());

        let (head, data) = data.split_at_mut(head_ks.len());
        let (blocks, tail) = Array::slice_as_chunks_mut(data);

        head.copy_from_slice(head_ks);
        self.core.write_keystream_blocks(blocks);

        self.buffer.write_block(
            tail.len(),
            |b| self.core.write_keystream_block(b),
            |tail_ks| tail.copy_from_slice(tail_ks),
        );

        Ok(())
    }
}

impl<T: StreamCipherSeekCore> StreamCipherSeek for StreamCipherCoreWrapper<T> {
    fn try_current_pos<SN: SeekNum>(&self) -> Result<SN, OverflowError> {
        let pos = u8::try_from(self.buffer.get_pos())
            .expect("buffer position is always smaller than 256");
        SN::from_block_byte(self.core.get_block_pos(), pos, T::BlockSize::U8)
    }

    fn try_seek<SN: SeekNum>(&mut self, new_pos: SN) -> Result<(), StreamCipherError> {
        let (block_pos, byte_pos) = new_pos.into_block_byte(T::BlockSize::U8)?;
        // For correct implementations of `SeekNum` compiler should be able to
        // eliminate this assert
        assert!(byte_pos < T::BlockSize::U8);

        self.core.set_block_pos(block_pos);

        self.buffer.reset();

        self.buffer.write_block(
            usize::from(byte_pos),
            |b| self.core.write_keystream_block(b),
            |_| {},
        );
        Ok(())
    }
}

// Note: ideally we would only implement the InitInner trait and everything
// else would be handled by blanket impls, but, unfortunately, it will
// not work properly without mutually exclusive traits, see:
// https://github.com/rust-lang/rfcs/issues/1053

impl<T: KeySizeUser + StreamCipherCore> KeySizeUser for StreamCipherCoreWrapper<T> {
    type KeySize = T::KeySize;
}

impl<T: IvSizeUser + StreamCipherCore> IvSizeUser for StreamCipherCoreWrapper<T> {
    type IvSize = T::IvSize;
}

impl<T: KeyIvInit + StreamCipherCore> KeyIvInit for StreamCipherCoreWrapper<T> {
    #[inline]
    fn new(key: &Key<Self>, iv: &Iv<Self>) -> Self {
        Self {
            core: T::new(key, iv),
            buffer: Default::default(),
        }
    }
}

impl<T: KeyInit + StreamCipherCore> KeyInit for StreamCipherCoreWrapper<T> {
    #[inline]
    fn new(key: &Key<Self>) -> Self {
        Self {
            core: T::new(key),
            buffer: Default::default(),
        }
    }
}

#[cfg(feature = "zeroize")]
impl<T: StreamCipherCore + ZeroizeOnDrop> ZeroizeOnDrop for StreamCipherCoreWrapper<T> {}

// Assert that `ReadBuffer` implements `ZeroizeOnDrop`
#[cfg(feature = "zeroize")]
const _: () = {
    #[allow(dead_code)]
    fn check_buffer<BS: crate::array::ArraySize>(v: &ReadBuffer<BS>) {
        let _ = v as &dyn crate::zeroize::ZeroizeOnDrop;
    }
};
