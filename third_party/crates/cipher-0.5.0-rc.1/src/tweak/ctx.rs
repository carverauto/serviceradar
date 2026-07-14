use crypto_common::{Block, BlockSizeUser, BlockSizes, array::ArraySize};
use inout::InOut;

use super::{
    Tweak, TweakBlockCipherDecBackend, TweakBlockCipherDecClosure, TweakBlockCipherEncBackend,
    TweakBlockCipherEncClosure, TweakSizeUser,
};

/// Closure used in methods which operate over separate blocks.
pub(super) struct BlockCtx<'a, TS: ArraySize, BS: BlockSizes> {
    pub tweak: &'a Tweak<Self>,
    pub block: InOut<'a, 'a, Block<Self>>,
}

impl<TS: ArraySize, BS: BlockSizes> BlockSizeUser for BlockCtx<'_, TS, BS> {
    type BlockSize = BS;
}

impl<TS: ArraySize, BS: BlockSizes> TweakSizeUser for BlockCtx<'_, TS, BS> {
    type TweakSize = TS;
}

impl<TS: ArraySize, BS: BlockSizes> TweakBlockCipherEncClosure for BlockCtx<'_, TS, BS> {
    #[inline]
    fn call<B>(self, backend: &B)
    where
        B: TweakBlockCipherEncBackend<BlockSize = BS, TweakSize = TS>,
    {
        backend.encrypt_block_inout(self.tweak, self.block);
    }
}

impl<TS: ArraySize, BS: BlockSizes> TweakBlockCipherDecClosure for BlockCtx<'_, TS, BS> {
    #[inline]
    fn call<B>(self, backend: &B)
    where
        B: TweakBlockCipherDecBackend<BlockSize = BS, TweakSize = TS>,
    {
        backend.decrypt_block_inout(self.tweak, self.block);
    }
}
