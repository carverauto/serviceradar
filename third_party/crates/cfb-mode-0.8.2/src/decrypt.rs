use cipher::{
    crypto_common::{InnerUser, IvSizeUser},
    generic_array::{ArrayLength, GenericArray},
    inout::InOut,
    AlgorithmName, AsyncStreamCipher, Block, BlockBackend, BlockCipher, BlockClosure, BlockDecrypt,
    BlockDecryptMut, BlockEncryptMut, BlockSizeUser, InnerIvInit, Iv, IvState, ParBlocks,
    ParBlocksSizeUser, Unsigned,
};
use core::fmt;

#[cfg(feature = "zeroize")]
use cipher::zeroize::{Zeroize, ZeroizeOnDrop};

/// CFB mode decryptor.
#[derive(Clone)]
pub struct Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    cipher: C,
    iv: Block<C>,
}

/// CFB mode buffered decryptor.
#[derive(Clone)]
pub struct BufDecryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    cipher: C,
    iv: Block<C>,
    pos: usize,
}

impl<C> BufDecryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    /// Decrypt a buffer in multiple parts.
    pub fn decrypt(&mut self, mut data: &mut [u8]) {
        let bs = C::BlockSize::to_usize();
        let n = data.len();

        if n < bs - self.pos {
            xor_set2(data, &mut self.iv[self.pos..self.pos + n]);
            self.pos += n;
            return;
        }
        let (left, right) = { data }.split_at_mut(bs - self.pos);
        data = right;
        let mut iv = self.iv.clone();
        xor_set2(left, &mut iv[self.pos..]);
        self.cipher.encrypt_block_mut(&mut iv);

        let mut chunks = data.chunks_exact_mut(bs);
        for chunk in &mut chunks {
            xor_set2(chunk, iv.as_mut_slice());
            self.cipher.encrypt_block_mut(&mut iv);
        }

        let rem = chunks.into_remainder();
        xor_set2(rem, iv.as_mut_slice());
        self.pos = rem.len();
        self.iv = iv;
    }

    /// Returns the current state (block and position) of the decryptor.
    pub fn get_state(&self) -> (&Block<C>, usize) {
        (&self.iv, self.pos)
    }

    /// Restore from the given state for resumption.
    pub fn from_state(cipher: C, iv: &Block<C>, pos: usize) -> Self {
        Self {
            cipher,
            iv: iv.clone(),
            pos,
        }
    }
}

impl<C> BlockSizeUser for Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type BlockSize = C::BlockSize;
}

impl<C> BlockDecryptMut for Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    fn decrypt_with_backend_mut(&mut self, f: impl BlockClosure<BlockSize = Self::BlockSize>) {
        let Self { cipher, iv } = self;
        cipher.encrypt_with_backend_mut(Closure { iv, f })
    }
}

impl<C> AsyncStreamCipher for Decryptor<C> where C: BlockEncryptMut + BlockCipher {}

impl<C> InnerUser for Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type Inner = C;
}

impl<C> InnerUser for BufDecryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type Inner = C;
}

impl<C> IvSizeUser for Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type IvSize = C::BlockSize;
}

impl<C> IvSizeUser for BufDecryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type IvSize = C::BlockSize;
}

impl<C> InnerIvInit for Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    #[inline]
    fn inner_iv_init(mut cipher: C, iv: &Iv<Self>) -> Self {
        let mut iv = iv.clone();
        cipher.encrypt_block_mut(&mut iv);
        Self { cipher, iv }
    }
}

impl<C> InnerIvInit for BufDecryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    #[inline]
    fn inner_iv_init(mut cipher: C, iv: &Iv<Self>) -> Self {
        let mut iv = iv.clone();
        cipher.encrypt_block_mut(&mut iv);
        Self { cipher, iv, pos: 0 }
    }
}

impl<C> IvState for Decryptor<C>
where
    C: BlockEncryptMut + BlockDecrypt + BlockCipher,
{
    #[inline]
    fn iv_state(&self) -> Iv<Self> {
        let mut res = self.iv.clone();
        self.cipher.decrypt_block(&mut res);
        res
    }
}

impl<C> AlgorithmName for Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::Decryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<C> AlgorithmName for BufDecryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::BufDecryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<C> fmt::Debug for Decryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::Decryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

impl<C> fmt::Debug for BufDecryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::BufDecryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher> Drop for Decryptor<C> {
    fn drop(&mut self) {
        self.iv.zeroize();
    }
}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher> Drop for BufDecryptor<C> {
    fn drop(&mut self) {
        self.iv.zeroize();
    }
}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher + ZeroizeOnDrop> ZeroizeOnDrop for Decryptor<C> {}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher + ZeroizeOnDrop> ZeroizeOnDrop for BufDecryptor<C> {}

struct Closure<'a, BS, BC>
where
    BS: ArrayLength<u8>,
    BC: BlockClosure<BlockSize = BS>,
{
    iv: &'a mut GenericArray<u8, BS>,
    f: BC,
}

impl<'a, BS, BC> BlockSizeUser for Closure<'a, BS, BC>
where
    BS: ArrayLength<u8>,
    BC: BlockClosure<BlockSize = BS>,
{
    type BlockSize = BS;
}

impl<'a, BS, BC> BlockClosure for Closure<'a, BS, BC>
where
    BS: ArrayLength<u8>,
    BC: BlockClosure<BlockSize = BS>,
{
    #[inline(always)]
    fn call<B: BlockBackend<BlockSize = Self::BlockSize>>(self, backend: &mut B) {
        let Self { iv, f } = self;
        f.call(&mut Backend { iv, backend });
    }
}

struct Backend<'a, BS, BK>
where
    BS: ArrayLength<u8>,
    BK: BlockBackend<BlockSize = BS>,
{
    iv: &'a mut GenericArray<u8, BS>,
    backend: &'a mut BK,
}

impl<'a, BS, BK> BlockSizeUser for Backend<'a, BS, BK>
where
    BS: ArrayLength<u8>,
    BK: BlockBackend<BlockSize = BS>,
{
    type BlockSize = BS;
}

impl<'a, BS, BK> ParBlocksSizeUser for Backend<'a, BS, BK>
where
    BS: ArrayLength<u8>,
    BK: BlockBackend<BlockSize = BS>,
{
    type ParBlocksSize = BK::ParBlocksSize;
}

impl<'a, BS, BK> BlockBackend for Backend<'a, BS, BK>
where
    BS: ArrayLength<u8>,
    BK: BlockBackend<BlockSize = BS>,
{
    #[inline(always)]
    fn proc_block(&mut self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut t = block.clone_in();
        block.xor_in2out(self.iv);
        self.backend.proc_block((&mut t).into());
        *self.iv = t;
    }

    #[inline(always)]
    fn proc_par_blocks(&mut self, mut blocks: InOut<'_, '_, ParBlocks<Self>>) {
        let mut t = ParBlocks::<Self>::default();
        let b = (blocks.get_in(), &mut t).into();
        self.backend.proc_par_blocks(b);

        let n = t.len();
        blocks.get(0).xor_in2out(self.iv);
        for i in 1..n {
            blocks.get(i).xor_in2out(&t[i - 1])
        }
        *self.iv = t[n - 1].clone();
    }
}

#[inline(always)]
fn xor_set2(buf1: &mut [u8], buf2: &mut [u8]) {
    for (a, b) in buf1.iter_mut().zip(buf2) {
        let t = *a;
        *a ^= *b;
        *b = t;
    }
}
