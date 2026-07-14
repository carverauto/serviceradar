use crate::CtrFlavor;
use cipher::{
    AlgorithmName, Block, BlockCipherEncBackend, BlockCipherEncClosure, BlockCipherEncrypt,
    BlockSizeUser, InnerIvInit, Iv, IvState, ParBlocks, ParBlocksSizeUser, StreamCipherBackend,
    StreamCipherClosure, StreamCipherCore, StreamCipherSeekCore,
    array::ArraySize,
    crypto_common::{BlockSizes, InnerUser, IvSizeUser},
};
use core::fmt;

#[cfg(feature = "zeroize")]
use cipher::zeroize::ZeroizeOnDrop;

/// Generic CTR block mode instance.
pub struct CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    cipher: C,
    ctr_nonce: F::CtrNonce,
}

impl<C, F> BlockSizeUser for CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    type BlockSize = C::BlockSize;
}

impl<C, F> StreamCipherCore for CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    #[inline]
    fn remaining_blocks(&self) -> Option<usize> {
        F::remaining(&self.ctr_nonce)
    }

    #[inline]
    fn process_with_backend(&mut self, f: impl StreamCipherClosure<BlockSize = Self::BlockSize>) {
        struct Closure<'a, F, BS, SC>
        where
            BS: ArraySize,
            F: CtrFlavor<BS>,
            SC: StreamCipherClosure<BlockSize = BS>,
        {
            ctr_nonce: &'a mut F::CtrNonce,
            f: SC,
        }

        impl<F, BS, SC> BlockSizeUser for Closure<'_, F, BS, SC>
        where
            BS: BlockSizes,
            F: CtrFlavor<BS>,
            SC: StreamCipherClosure<BlockSize = BS>,
        {
            type BlockSize = BS;
        }

        impl<F, BS, SC> BlockCipherEncClosure for Closure<'_, F, BS, SC>
        where
            BS: BlockSizes,
            F: CtrFlavor<BS>,
            SC: StreamCipherClosure<BlockSize = BS>,
        {
            #[inline(always)]
            fn call<B: BlockCipherEncBackend<BlockSize = BS>>(self, backend: &B) {
                let Self { ctr_nonce, f } = self;
                f.call(&mut Backend::<F, B> { ctr_nonce, backend })
            }
        }

        let Self { cipher, ctr_nonce } = self;
        cipher.encrypt_with_backend(Closure::<F, _, _> { ctr_nonce, f });
    }
}

impl<C, F> StreamCipherSeekCore for CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    type Counter = F::Backend;

    #[inline]
    fn get_block_pos(&self) -> Self::Counter {
        F::as_backend(&self.ctr_nonce)
    }

    #[inline]
    fn set_block_pos(&mut self, pos: Self::Counter) {
        F::set_from_backend(&mut self.ctr_nonce, pos);
    }
}

impl<C, F> InnerUser for CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    type Inner = C;
}

impl<C, F> IvSizeUser for CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    type IvSize = C::BlockSize;
}

impl<C, F> InnerIvInit for CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    #[inline]
    fn inner_iv_init(cipher: C, iv: &Iv<Self>) -> Self {
        Self {
            cipher,
            ctr_nonce: F::from_nonce(iv),
        }
    }
}

impl<C, F> IvState for CtrCore<C, F>
where
    C: BlockCipherEncrypt,
    F: CtrFlavor<C::BlockSize>,
{
    #[inline]
    fn iv_state(&self) -> Iv<Self> {
        F::current_block(&self.ctr_nonce)
    }
}

impl<C, F> AlgorithmName for CtrCore<C, F>
where
    C: BlockCipherEncrypt + AlgorithmName,
    F: CtrFlavor<C::BlockSize>,
{
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Ctr")?;
        f.write_str(F::NAME)?;
        f.write_str("<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<C, F> Clone for CtrCore<C, F>
where
    C: BlockCipherEncrypt + Clone,
    F: CtrFlavor<C::BlockSize>,
{
    #[inline]
    fn clone(&self) -> Self {
        Self {
            cipher: self.cipher.clone(),
            ctr_nonce: self.ctr_nonce.clone(),
        }
    }
}

impl<C, F> fmt::Debug for CtrCore<C, F>
where
    C: BlockCipherEncrypt + AlgorithmName,
    F: CtrFlavor<C::BlockSize>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Ctr")?;
        f.write_str(F::NAME)?;
        f.write_str("<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

#[cfg(feature = "zeroize")]
impl<C, F> ZeroizeOnDrop for CtrCore<C, F>
where
    C: BlockCipherEncrypt + ZeroizeOnDrop,
    F: CtrFlavor<C::BlockSize>,
    F::CtrNonce: ZeroizeOnDrop,
{
}

struct Backend<'a, F, B>
where
    F: CtrFlavor<B::BlockSize>,
    B: BlockCipherEncBackend,
{
    ctr_nonce: &'a mut F::CtrNonce,
    backend: &'a B,
}

impl<F, B> BlockSizeUser for Backend<'_, F, B>
where
    F: CtrFlavor<B::BlockSize>,
    B: BlockCipherEncBackend,
{
    type BlockSize = B::BlockSize;
}

impl<F, B> ParBlocksSizeUser for Backend<'_, F, B>
where
    F: CtrFlavor<B::BlockSize>,
    B: BlockCipherEncBackend,
{
    type ParBlocksSize = B::ParBlocksSize;
}

impl<F, B> StreamCipherBackend for Backend<'_, F, B>
where
    F: CtrFlavor<B::BlockSize>,
    B: BlockCipherEncBackend,
{
    #[inline(always)]
    fn gen_ks_block(&mut self, block: &mut Block<Self>) {
        let tmp = F::next_block(self.ctr_nonce);
        self.backend.encrypt_block((&tmp, block).into());
    }

    #[inline(always)]
    fn gen_par_ks_blocks(&mut self, blocks: &mut ParBlocks<Self>) {
        let mut tmp = ParBlocks::<Self>::default();
        for block in tmp.iter_mut() {
            *block = F::next_block(self.ctr_nonce);
        }
        self.backend.encrypt_par_blocks((&tmp, blocks).into());
    }
}
