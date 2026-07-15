use cipher::{
    consts::U1,
    crypto_common::{InnerUser, IvSizeUser},
    generic_array::{ArrayLength, GenericArray},
    inout::InOut,
    AlgorithmName, AsyncStreamCipher, Block, BlockBackend, BlockCipher, BlockClosure, BlockDecrypt,
    BlockEncryptMut, BlockSizeUser, InnerIvInit, Iv, IvState, ParBlocksSizeUser, Unsigned,
};
use core::fmt;

#[cfg(feature = "zeroize")]
use cipher::zeroize::{Zeroize, ZeroizeOnDrop};

/// CFB mode encryptor.
#[derive(Clone)]
pub struct Encryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    cipher: C,
    iv: Block<C>,
}

/// CFB mode buffered encryptor.
#[derive(Clone)]
pub struct BufEncryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    cipher: C,
    iv: Block<C>,
    pos: usize,
}

impl<C> BufEncryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    /// Encrypt a buffer in multiple parts.
    pub fn encrypt(&mut self, mut data: &mut [u8]) {
        let bs = C::BlockSize::USIZE;
        let n = data.len();

        if n < bs - self.pos {
            xor_set1(data, &mut self.iv[self.pos..self.pos + n]);
            self.pos += n;
            return;
        }

        let (left, right) = { data }.split_at_mut(bs - self.pos);
        data = right;
        let mut iv = self.iv.clone();
        xor_set1(left, &mut iv[self.pos..]);
        self.cipher.encrypt_block_mut(&mut iv);

        let mut chunks = data.chunks_exact_mut(bs);
        for chunk in &mut chunks {
            xor_set1(chunk, iv.as_mut_slice());
            self.cipher.encrypt_block_mut(&mut iv);
        }

        let rem = chunks.into_remainder();
        xor_set1(rem, iv.as_mut_slice());
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

impl<C> BlockSizeUser for Encryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type BlockSize = C::BlockSize;
}

impl<C> BlockEncryptMut for Encryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    fn encrypt_with_backend_mut(&mut self, f: impl BlockClosure<BlockSize = Self::BlockSize>) {
        let Self { cipher, iv } = self;
        cipher.encrypt_with_backend_mut(Closure { iv, f })
    }
}

impl<C> AsyncStreamCipher for Encryptor<C> where C: BlockEncryptMut + BlockCipher {}

impl<C> InnerUser for Encryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type Inner = C;
}

impl<C> InnerUser for BufEncryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type Inner = C;
}

impl<C> IvSizeUser for Encryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type IvSize = C::BlockSize;
}

impl<C> IvSizeUser for BufEncryptor<C>
where
    C: BlockEncryptMut + BlockCipher,
{
    type IvSize = C::BlockSize;
}

impl<C> InnerIvInit for Encryptor<C>
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

impl<C> InnerIvInit for BufEncryptor<C>
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

impl<C> IvState for Encryptor<C>
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

impl<C> AlgorithmName for BufEncryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::BufEncryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<C> AlgorithmName for Encryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::Encryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<C> fmt::Debug for Encryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::Encryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

impl<C> fmt::Debug for BufEncryptor<C>
where
    C: BlockEncryptMut + BlockCipher + AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("cfb::BufEncryptor<")?;
        <C as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher> Drop for Encryptor<C> {
    fn drop(&mut self) {
        self.iv.zeroize();
    }
}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher> Drop for BufEncryptor<C> {
    fn drop(&mut self) {
        self.iv.zeroize();
    }
}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher + ZeroizeOnDrop> ZeroizeOnDrop for Encryptor<C> {}

#[cfg(feature = "zeroize")]
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl<C: BlockEncryptMut + BlockCipher + ZeroizeOnDrop> ZeroizeOnDrop for BufEncryptor<C> {}

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
    type ParBlocksSize = U1;
}

impl<'a, BS, BK> BlockBackend for Backend<'a, BS, BK>
where
    BS: ArrayLength<u8>,
    BK: BlockBackend<BlockSize = BS>,
{
    #[inline(always)]
    fn proc_block(&mut self, mut block: InOut<'_, '_, Block<Self>>) {
        block.xor_in2out(self.iv);
        let mut t = block.get_out().clone();
        self.backend.proc_block((&mut t).into());
        *self.iv = t;
    }
}

#[inline(always)]
fn xor_set1(buf1: &mut [u8], buf2: &mut [u8]) {
    for (a, b) in buf1.iter_mut().zip(buf2) {
        let t = *a ^ *b;
        *a = t;
        *b = t;
    }
}
