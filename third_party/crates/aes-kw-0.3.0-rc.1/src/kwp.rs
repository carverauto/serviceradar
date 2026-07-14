use core::ops::{Add, Div, Mul};

use crate::{Error, IV_LEN, IntegrityCheckFailed, IvLen, ctx::Ctx};
use aes::cipher::{
    Array, Block, BlockCipherDecrypt, BlockCipherEncrypt,
    array::ArraySize,
    consts::{B1, U7, U4294967296},
    crypto_common::{InnerInit, InnerUser},
    typenum::{Add1, IsLess, Le, NonZero, Prod, Quot, Sum, U16},
};

/// Maximum length of the AES-KWP input data (2^32 bytes) represented as a `typenum` type.
type KwpMaxLen = U4294967296;
/// Maximum length of the AES-KWP input data (2^32 - 1 bytes).
const KWP_MAX_LEN: usize = u32::MAX as usize;

/// Alternative Initial Value constant prefix for AES-KWP as defined in RFC 3394 § 3.
///
/// <https://datatracker.ietf.org/doc/html/rfc5649#section-3>
///
/// ```text
/// The Alternative Initial Value (AIV) required by this specification is
//  a 32-bit constant concatenated to a 32-bit MLI.  The constant is (in
//  hexadecimal) A65959A6 and occupies the high-order half of the AIV.
/// ```
const KWP_IV_PREFIX: [u8; IV_LEN / 2] = [0xA6, 0x59, 0x59, 0xA6];

/// [`IvLen`] (`U8`) minus one
type IvLenM1 = U7;

/// Type alias representing wrapped key roughly equivalent to
/// `[u8; IV_LEN * (N.div_ceil(IV_LEN) + 1)]`.
pub type KwpWrappedKey<N> = Array<u8, Prod<Add1<Quot<Sum<N, IvLenM1>, IvLen>>, IvLen>>;

/// AES Key Wrapper with Padding (KWP), as defined in [RFC 5649].
///
/// [RFC 5649]: https://www.rfc-editor.org/rfc/rfc5649.txt
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AesKwp<C> {
    cipher: C,
}

impl<C> InnerUser for AesKwp<C> {
    type Inner = C;
}

impl<C> InnerInit for AesKwp<C> {
    #[inline]
    fn inner_init(cipher: Self::Inner) -> Self {
        AesKwp { cipher }
    }
}

impl<C: BlockCipherEncrypt<BlockSize = U16>> AesKwp<C> {
    /// Wrap key into `buf` assuming that it has correct length.
    fn wrap_key_trusted(&self, key: &[u8], buf: &mut [u8]) {
        let semiblocks_len = key.len().div_ceil(IV_LEN);

        // 2) Wrapping

        // 2.1) Initialize variables

        // Set A to the AIV
        let block = &mut Block::<C>::default();
        let (prefix, mli) = block[..IV_LEN].split_at_mut(IV_LEN / 2);
        prefix.copy_from_slice(&KWP_IV_PREFIX);
        // 32-bit MLI equal to the number of bytes in the input data, big endian
        mli.copy_from_slice(&(key.len() as u32).to_be_bytes());

        // If semiblocks_len is 1, the plaintext is encrypted as a single AES block
        if semiblocks_len == 1 {
            // 1) Append padding

            block[IV_LEN..][..key.len()].copy_from_slice(key);
            self.cipher
                .encrypt_block_b2b(block, buf.try_into().unwrap());
        } else {
            // 1) Append padding

            // 2.2) Calculate intermediate values
            buf[IV_LEN..][..key.len()].copy_from_slice(key);

            self.cipher.encrypt_with_backend(Ctx {
                blocks_len: semiblocks_len,
                block,
                buf,
            });

            // 2.3) Output the results
            buf[..IV_LEN].copy_from_slice(&block[..IV_LEN]);
        }
    }

    /// AES Key Wrap with Padding, as defined in RFC 5649.
    ///
    /// The `buf` buffer will be overwritten, and must be the smallest
    /// multiple of [`IV_LEN`] (i.e. 8) which is at least [`IV_LEN`]
    /// bytes (i.e. 8 bytes) longer than the length of `data`.
    #[inline]
    pub fn wrap_key<'a>(&self, key: &[u8], buf: &'a mut [u8]) -> Result<&'a [u8], Error> {
        if key.len() > KWP_MAX_LEN {
            return Err(Error::InvalidDataSize);
        }

        // 0) Prepare inputs

        // number of 64 bit blocks in the input data (padded)
        let semiblocks_len = key.len().div_ceil(IV_LEN);

        let expected_len = semiblocks_len * IV_LEN + IV_LEN;
        let buf = buf
            .get_mut(..expected_len)
            .ok_or(Error::InvalidOutputSize { expected_len })?;

        self.wrap_key_trusted(key, buf);

        Ok(buf)
    }

    /// Wrap fixed-size key `key` and return wrapped key.
    ///
    /// This method is roughly equivalent to:
    /// ```ignore
    /// pub fn wrap_fixed_key<const N: usize>(
    ///     &self,
    ///     key: &[u8; N],
    /// ) -> [u8; IV_LEN * (N.div_ceil(IV_LEN) + 1)]
    /// { ... }
    /// ```
    /// but uses [`hybrid_array::Array`][Array] instead of built-in arrays
    /// to work around current limitations of the const generics system.
    #[inline]
    pub fn wrap_fixed_key<N>(&self, key: &Array<u8, N>) -> KwpWrappedKey<N>
    where
        N: ArraySize + Add<IvLenM1> + IsLess<KwpMaxLen>,
        Le<N, KwpMaxLen>: NonZero,
        Sum<N, IvLenM1>: Div<IvLen>,
        Quot<Sum<N, IvLenM1>, IvLen>: Add<B1>,
        Add1<Quot<Sum<N, IvLenM1>, IvLen>>: Mul<IvLen>,
        Prod<Add1<Quot<Sum<N, IvLenM1>, IvLen>>, IvLen>: ArraySize,
    {
        // 0) Prepare inputs

        // number of 64 bit blocks in the input data (padded)

        let semiblocks_len = key.len().div_ceil(IV_LEN);
        let mut buf = KwpWrappedKey::<N>::default();
        assert_eq!(semiblocks_len * IV_LEN + IV_LEN, buf.len());

        self.wrap_key_trusted(key, &mut buf);

        buf
    }
}

impl<C: BlockCipherDecrypt<BlockSize = U16>> AesKwp<C> {
    /// Unwrap key into `buf` assuming that it has correct length.
    fn unwrap_key_trusted<'a>(
        &self,
        wkey: &[u8],
        buf: &'a mut [u8],
    ) -> Result<&'a [u8], IntegrityCheckFailed> {
        let blocks_len = buf.len() / IV_LEN;

        // 1) Key unwrapping

        // 1.1) Initialize variables

        let block = &mut Block::<C>::default();

        // If n is 1, the plaintext is encrypted as a single AES block
        if blocks_len == 1 {
            block.copy_from_slice(wkey);
            self.cipher.decrypt_block(block);
            buf.copy_from_slice(&block[IV_LEN..]);
        } else {
            block[..IV_LEN].copy_from_slice(&wkey[..IV_LEN]);

            //   for i = 1 to n: R[i] = C[i]
            buf.copy_from_slice(&wkey[IV_LEN..]);

            // 1.2) Calculate intermediate values

            self.cipher.decrypt_with_backend(Ctx {
                blocks_len,
                block,
                buf,
            });
        }

        // 2) AIV verification

        // Checks as defined in RFC5649 § 3

        let prefix_calc = u32::from_ne_bytes(block[..IV_LEN / 2].try_into().unwrap());
        let prefix_exp = u32::from_ne_bytes(KWP_IV_PREFIX);
        if prefix_calc != prefix_exp {
            buf.fill(0);
            return Err(IntegrityCheckFailed);
        }

        let mli_bytes = block[IV_LEN / 2..IV_LEN].try_into().unwrap();
        let mli: usize = usize::try_from(u32::from_be_bytes(mli_bytes)).map_err(|_| {
            buf.fill(0);
            IntegrityCheckFailed
        })?;
        if mli.div_ceil(IV_LEN) != blocks_len {
            buf.fill(0);
            return Err(IntegrityCheckFailed);
        }

        let (res, pad) = buf.split_at_mut(mli);
        if !pad.iter().all(|&b| b == 0) {
            res.fill(0);
            pad.fill(0);
            return Err(IntegrityCheckFailed);
        }

        Ok(res)
    }

    /// AES Key Wrap with Padding, as defined in RFC 5649.
    ///
    /// The `buf` buffer will be overwritten, and must be exactly [`IV_LEN`]
    /// bytes (i.e. 8 bytes) shorter than the length of `data`.
    /// This method returns a slice of `out`, truncated to the appropriate
    /// length by removing the padding.
    #[inline]
    pub fn unwrap_key<'a>(&self, data: &[u8], buf: &'a mut [u8]) -> Result<&'a [u8], Error> {
        let blocks_len = data.len() / IV_LEN;
        let blocks_rem = data.len() % IV_LEN;
        if blocks_rem != 0 || blocks_len < 1 || data.len() > KWP_MAX_LEN {
            return Err(Error::InvalidDataSize);
        }

        let blocks_len = blocks_len - 1;
        let expected_len = blocks_len * IV_LEN;
        let buf = buf
            .get_mut(..expected_len)
            .ok_or(Error::InvalidOutputSize { expected_len })?;

        self.unwrap_key_trusted(data, buf)
            .map_err(|_| Error::IntegrityCheckFailed)
    }

    /// Unwrap fixed-size wrapped key `wkey` and return resulting key.
    ///
    /// This method is roughly equivalent to:
    /// ```ignore
    /// pub fn unwrap_fixed_key<const N: usize>(
    ///     &self,
    ///     wkey: &[u8; IV_LEN * (N.div_ceil(IV_LEN) + 1)],
    /// ) -> [u8; N]
    /// { ... }
    /// ```
    /// but uses [`hybrid_array::Array`][Array] instead of built-in arrays
    /// to work around current limitations of the const generics system.
    #[inline]
    pub fn unwrap_fixed_key<N>(
        &self,
        wkey: &KwpWrappedKey<N>,
    ) -> Result<Array<u8, N>, IntegrityCheckFailed>
    where
        N: ArraySize + Add<IvLenM1> + IsLess<KwpMaxLen>,
        Le<N, KwpMaxLen>: NonZero,
        Sum<N, IvLenM1>: Div<IvLen>,
        Quot<Sum<N, IvLenM1>, IvLen>: Add<B1> + Mul<IvLen>,
        Add1<Quot<Sum<N, IvLenM1>, IvLen>>: Mul<IvLen>,
        Prod<Add1<Quot<Sum<N, IvLenM1>, IvLen>>, IvLen>: ArraySize,
        Prod<Quot<Sum<N, IvLenM1>, IvLen>, IvLen>: ArraySize,
    {
        let mut buf = Array::<u8, Prod<Quot<Sum<N, IvLenM1>, IvLen>, IvLen>>::default();
        self.unwrap_key_trusted(wkey, &mut buf)
            .map(|res| res.try_into().unwrap())
    }
}
