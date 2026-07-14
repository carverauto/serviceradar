use crate::IV_LEN;
use aes::cipher::{
    Block, BlockCipherDecBackend, BlockCipherDecClosure, BlockCipherEncBackend,
    BlockCipherEncClosure, BlockSizeUser, typenum::U16,
};

pub(crate) struct Ctx<'a> {
    pub(crate) blocks_len: usize,
    pub(crate) block: &'a mut Block<Self>,
    pub(crate) buf: &'a mut [u8],
}

impl BlockSizeUser for Ctx<'_> {
    type BlockSize = U16;
}

/// Very similar to the W(S) function defined by NIST in SP 800-38F, Section 6.1
impl BlockCipherEncClosure for Ctx<'_> {
    #[inline(always)]
    fn call<B: BlockCipherEncBackend<BlockSize = U16>>(self, backend: &B) {
        for j in 0..=5 {
            for (i, chunk) in self.buf.chunks_mut(IV_LEN).skip(1).enumerate() {
                // A | R[i]
                self.block[IV_LEN..].copy_from_slice(chunk);
                // B = AES(K, ..)
                backend.encrypt_block(self.block.into());

                // A = MSB(64, B) ^ t
                let t = (self.blocks_len * j + (i + 1)) as u64;
                for (ai, ti) in self.block[..IV_LEN].iter_mut().zip(&t.to_be_bytes()) {
                    *ai ^= ti;
                }

                // R[i] = LSB(64, B)
                chunk.copy_from_slice(&self.block[IV_LEN..]);
            }
        }
    }
}

/// Very similar to the W^-1(S) function defined by NIST in SP 800-38F, Section 6.1
impl BlockCipherDecClosure for Ctx<'_> {
    #[inline(always)]
    fn call<B: BlockCipherDecBackend<BlockSize = U16>>(self, backend: &B) {
        for j in (0..=5).rev() {
            for (i, chunk) in self.buf.chunks_mut(IV_LEN).enumerate().rev() {
                // A ^ t
                let t = (self.blocks_len * j + (i + 1)) as u64;
                for (ai, ti) in self.block[..IV_LEN].iter_mut().zip(&t.to_be_bytes()) {
                    *ai ^= ti;
                }

                // (A ^ t) | R[i]
                self.block[IV_LEN..].copy_from_slice(chunk);

                // B = AES-1(K, ..)
                backend.decrypt_block(self.block.into());

                // A = MSB(64, B)
                // already set

                // R[i] = LSB(64, B)
                chunk.copy_from_slice(&self.block[IV_LEN..]);
            }
        }
    }
}
