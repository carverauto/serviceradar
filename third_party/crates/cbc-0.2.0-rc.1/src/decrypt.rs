use crate::xor;
use cipher::{
    AlgorithmName, Block, BlockCipherDecBackend, BlockCipherDecClosure, BlockCipherDecrypt,
    BlockModeDecBackend, BlockModeDecClosure, BlockModeDecrypt, BlockSizeUser, InnerIvInit, Iv,
    IvState, ParBlocks, ParBlocksSizeUser,
    array::Array,
    crypto_common::{BlockSizes, InnerUser, IvSizeUser},
    inout::InOut,
};
use core::fmt;

#[cfg(feature = "zeroize")]
use cipher::zeroize::{Zeroize, ZeroizeOnDrop};

/// CBC mode decryptor.
#[derive(Clone)]
pub struct Decryptor<C>
where
    C: BlockCipherDecrypt,
{
    cipher: C,
    iv: Block<C>,
}

impl<C> BlockSizeUser for Decryptor<C>
where
    C: BlockCipherDecrypt,
{
    type BlockSize = C::BlockSize;
}

impl<C> BlockModeDecrypt for Decryptor<C>
where
    C: BlockCipherDecrypt,
{
    fn decrypt_with_backend(&mut self, f: impl BlockModeDecClosure<BlockSize = Self::BlockSize>) {
        struct Closure<'a, BS, BC>
        where
            BS: BlockSizes,
            BC: BlockModeDecClosure<BlockSize = BS>,
        {
            iv: &'a mut Array<u8, BS>,
            f: BC,
        }

        impl<BS, BC> BlockSizeUser for Closure<'_, BS, BC>
        where
            BS: BlockSizes,
            BC: BlockModeDecClosure<BlockSize = BS>,
        {
            type BlockSize = BS;
        }

        impl<BS, BC> BlockCipherDecClosure for Closure<'_, BS, BC>
        where
            BS: BlockSizes,
            BC: BlockModeDecClosure<BlockSize = BS>,
        {
            #[inline(always)]
            fn call<B: BlockCipherDecBackend<BlockSize = Self::BlockSize>>(
                self,
                cipher_backend: &B,
            ) {
                let Self { iv, f } = self;
                f.call(&mut Backend { iv, cipher_backend });
            }
        }

        let Self { cipher, iv } = self;
        cipher.decrypt_with_backend(Closure { iv, f })
    }
}

impl<C> InnerUser for Decryptor<C>
where
    C: BlockCipherDecrypt,
{
    type Inner = C;
}

impl<C> IvSizeUser for Decryptor<C>
where
    C: BlockCipherDecrypt,
{
    type IvSize = C::BlockSize;
}

impl<C> InnerIvInit for Decryptor<C>
where
    C: BlockCipherDecrypt,
{
    #[inline]
    fn inner_iv_init(cipher: C, iv: &Iv<Self>) -> Self {
        Self {
            cipher,
            iv: iv.clone(),
        }
    }
}

impl<C> IvState for Decryptor<C>
where
    C: BlockCipherDecrypt,
{
    #[inline]
    fn iv_state(&self) -> Iv<Self> {
        self.iv.clone()
    }
}

impl<C> AlgorithmName for Decryptor<C>
where
    C: BlockCipherDecrypt + AlgorithmName,
{
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cbc::Decryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<C> fmt::Debug for Decryptor<C>
where
    C: BlockCipherDecrypt + AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cbc::Decryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

impl<C: BlockCipherDecrypt> Drop for Decryptor<C> {
    fn drop(&mut self) {
        #[cfg(feature = "zeroize")]
        self.iv.zeroize();
    }
}

#[cfg(feature = "zeroize")]
impl<C: BlockCipherDecrypt + ZeroizeOnDrop> ZeroizeOnDrop for Decryptor<C> {}

struct Backend<'a, BS, BK>
where
    BS: BlockSizes,
    BK: BlockCipherDecBackend<BlockSize = BS>,
{
    iv: &'a mut Array<u8, BS>,
    cipher_backend: &'a BK,
}

impl<BS, BK> BlockSizeUser for Backend<'_, BS, BK>
where
    BS: BlockSizes,
    BK: BlockCipherDecBackend<BlockSize = BS>,
{
    type BlockSize = BS;
}

impl<BS, BK> ParBlocksSizeUser for Backend<'_, BS, BK>
where
    BS: BlockSizes,
    BK: BlockCipherDecBackend<BlockSize = BS>,
{
    type ParBlocksSize = BK::ParBlocksSize;
}

impl<BS, BK> BlockModeDecBackend for Backend<'_, BS, BK>
where
    BS: BlockSizes,
    BK: BlockCipherDecBackend<BlockSize = BS>,
{
    #[inline(always)]
    fn decrypt_block(&mut self, mut block: InOut<'_, '_, Block<Self>>) {
        let in_block = block.clone_in();
        let mut t = block.clone_in();
        self.cipher_backend.decrypt_block((&mut t).into());
        xor(&mut t, self.iv);
        *block.get_out() = t;
        *self.iv = in_block;
    }

    #[inline(always)]
    fn decrypt_par_blocks(&mut self, mut blocks: InOut<'_, '_, ParBlocks<Self>>) {
        let in_blocks = blocks.clone_in();
        let mut t = blocks.clone_in();

        self.cipher_backend.decrypt_par_blocks((&mut t).into());
        let n = t.len();
        xor(&mut t[0], self.iv);
        for i in 1..n {
            xor(&mut t[i], &in_blocks[i - 1])
        }
        *blocks.get_out() = t;
        *self.iv = in_blocks[n - 1].clone();
    }
}
