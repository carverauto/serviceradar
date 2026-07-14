use crypto_common::{Block, BlockSizeUser, ParBlocks, ParBlocksSizeUser, typenum::Unsigned};
use inout::{InOut, InOutBuf};

/// Trait implemented by block cipher mode encryption backends.
pub trait BlockCipherEncBackend: ParBlocksSizeUser {
    /// Encrypt single inout block.
    fn encrypt_block(&self, block: InOut<'_, '_, Block<Self>>);

    /// Encrypt inout blocks in parallel.
    #[inline(always)]
    fn encrypt_par_blocks(&self, mut blocks: InOut<'_, '_, ParBlocks<Self>>) {
        for i in 0..Self::ParBlocksSize::USIZE {
            self.encrypt_block(blocks.get(i));
        }
    }

    /// Encrypt buffer of inout blocks. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn encrypt_tail_blocks(&self, blocks: InOutBuf<'_, '_, Block<Self>>) {
        assert!(blocks.len() < Self::ParBlocksSize::USIZE);
        for block in blocks {
            self.encrypt_block(block);
        }
    }

    /// Encrypt single block in-place.
    #[inline(always)]
    fn encrypt_block_inplace(&self, block: &mut Block<Self>) {
        self.encrypt_block(block.into());
    }

    /// Encrypt blocks in parallel in-place.
    #[inline(always)]
    fn encrypt_par_blocks_inplace(&self, blocks: &mut ParBlocks<Self>) {
        self.encrypt_par_blocks(blocks.into());
    }

    /// Encrypt buffer of blocks in-place. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn encrypt_tail_blocks_inplace(&self, blocks: &mut [Block<Self>]) {
        self.encrypt_tail_blocks(blocks.into());
    }
}

/// Trait for [`BlockCipherEncBackend`] users.
///
/// This trait is used to define rank-2 closures.
pub trait BlockCipherEncClosure: BlockSizeUser {
    /// Execute closure with the provided block cipher backend.
    fn call<B: BlockCipherEncBackend<BlockSize = Self::BlockSize>>(self, backend: &B);
}

/// Trait implemented by block cipher decryption backends.
pub trait BlockCipherDecBackend: ParBlocksSizeUser {
    /// Decrypt single inout block.
    fn decrypt_block(&self, block: InOut<'_, '_, Block<Self>>);

    /// Decrypt inout blocks in parallel.
    #[inline(always)]
    fn decrypt_par_blocks(&self, mut blocks: InOut<'_, '_, ParBlocks<Self>>) {
        for i in 0..Self::ParBlocksSize::USIZE {
            self.decrypt_block(blocks.get(i));
        }
    }

    /// Decrypt buffer of inout blocks. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn decrypt_tail_blocks(&self, blocks: InOutBuf<'_, '_, Block<Self>>) {
        assert!(blocks.len() < Self::ParBlocksSize::USIZE);
        for block in blocks {
            self.decrypt_block(block);
        }
    }

    /// Decrypt single block in-place.
    #[inline(always)]
    fn decrypt_block_inplace(&self, block: &mut Block<Self>) {
        self.decrypt_block(block.into());
    }

    /// Decrypt blocks in parallel in-place.
    #[inline(always)]
    fn decrypt_par_blocks_inplace(&self, blocks: &mut ParBlocks<Self>) {
        self.decrypt_par_blocks(blocks.into());
    }

    /// Decrypt buffer of blocks in-place. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn decrypt_tail_blocks_inplace(&self, blocks: &mut [Block<Self>]) {
        self.decrypt_tail_blocks(blocks.into());
    }
}

/// Trait for [`BlockCipherDecBackend`] users.
///
/// This trait is used to define rank-2 closures.
pub trait BlockCipherDecClosure: BlockSizeUser {
    /// Execute closure with the provided block cipher backend.
    fn call<B: BlockCipherDecBackend<BlockSize = Self::BlockSize>>(self, backend: &B);
}

/// Trait implemented by block cipher mode encryption backends.
pub trait BlockModeEncBackend: ParBlocksSizeUser {
    /// Encrypt single inout block.
    fn encrypt_block(&mut self, block: InOut<'_, '_, Block<Self>>);

    /// Encrypt inout blocks in parallel.
    #[inline(always)]
    fn encrypt_par_blocks(&mut self, mut blocks: InOut<'_, '_, ParBlocks<Self>>) {
        for i in 0..Self::ParBlocksSize::USIZE {
            self.encrypt_block(blocks.get(i));
        }
    }

    /// Encrypt buffer of inout blocks. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn encrypt_tail_blocks(&mut self, blocks: InOutBuf<'_, '_, Block<Self>>) {
        assert!(blocks.len() < Self::ParBlocksSize::USIZE);
        for block in blocks {
            self.encrypt_block(block);
        }
    }

    /// Encrypt single block in-place.
    #[inline(always)]
    fn encrypt_block_inplace(&mut self, block: &mut Block<Self>) {
        self.encrypt_block(block.into());
    }

    /// Encrypt blocks in parallel in-place.
    #[inline(always)]
    fn encrypt_par_blocks_inplace(&mut self, blocks: &mut ParBlocks<Self>) {
        self.encrypt_par_blocks(blocks.into());
    }

    /// Encrypt buffer of blocks in-place. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn encrypt_tail_blocks_inplace(&mut self, blocks: &mut [Block<Self>]) {
        self.encrypt_tail_blocks(blocks.into());
    }
}

/// Trait for [`BlockModeEncBackend`] users.
///
/// This trait is used to define rank-2 closures.
pub trait BlockModeEncClosure: BlockSizeUser {
    /// Execute closure with the provided block cipher backend.
    fn call<B: BlockModeEncBackend<BlockSize = Self::BlockSize>>(self, backend: &mut B);
}

/// Trait implemented by block cipher mode decryption backends.
pub trait BlockModeDecBackend: ParBlocksSizeUser {
    /// Decrypt single inout block.
    fn decrypt_block(&mut self, block: InOut<'_, '_, Block<Self>>);

    /// Decrypt inout blocks in parallel.
    #[inline(always)]
    fn decrypt_par_blocks(&mut self, mut blocks: InOut<'_, '_, ParBlocks<Self>>) {
        for i in 0..Self::ParBlocksSize::USIZE {
            self.decrypt_block(blocks.get(i));
        }
    }

    /// Decrypt buffer of inout blocks. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn decrypt_tail_blocks(&mut self, blocks: InOutBuf<'_, '_, Block<Self>>) {
        assert!(blocks.len() < Self::ParBlocksSize::USIZE);
        for block in blocks {
            self.decrypt_block(block);
        }
    }

    /// Decrypt single block in-place.
    #[inline(always)]
    fn decrypt_block_inplace(&mut self, block: &mut Block<Self>) {
        self.decrypt_block(block.into());
    }

    /// Decrypt blocks in parallel in-place.
    #[inline(always)]
    fn decrypt_par_blocks_inplace(&mut self, blocks: &mut ParBlocks<Self>) {
        self.decrypt_par_blocks(blocks.into());
    }

    /// Decrypt buffer of blocks in-place. Length of the buffer MUST be smaller
    /// than `Self::ParBlocksSize`.
    #[inline(always)]
    fn decrypt_tail_blocks_inplace(&mut self, blocks: &mut [Block<Self>]) {
        self.decrypt_tail_blocks(blocks.into());
    }
}

/// Trait for [`BlockModeDecBackend`] users.
///
/// This trait is used to define rank-2 closures.
pub trait BlockModeDecClosure: BlockSizeUser {
    /// Execute closure with the provided block cipher backend.
    fn call<B: BlockModeDecBackend<BlockSize = Self::BlockSize>>(self, backend: &mut B);
}
