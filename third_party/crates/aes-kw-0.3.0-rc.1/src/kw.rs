use core::ops::{Add, Rem};

use crate::{Error, IV_LEN, IvLen, ctx::Ctx, error::IntegrityCheckFailed};
use aes::cipher::{
    Array, Block, BlockCipherDecrypt, BlockCipherEncrypt,
    array::ArraySize,
    crypto_common::{InnerInit, InnerUser},
    typenum::{Mod, NonZero, Sum, U16, Zero},
};

/// Default Initial Value for AES-KW as defined in RFC3394 § 2.2.3.1.
///
/// <https://datatracker.ietf.org/doc/html/rfc3394#section-2.2.3.1>
///
/// ```text
/// The default initial value (IV) is defined to be the hexadecimal
/// constant:
///
///     A[0] = IV = A6A6A6A6A6A6A6A6
///
/// The use of a constant as the IV supports a strong integrity check on
/// the key data during the period that it is wrapped.  If unwrapping
/// produces A[0] = A6A6A6A6A6A6A6A6, then the chance that the key data
/// is corrupt is 2^-64.  If unwrapping produces A[0] any other value,
/// then the unwrap must return an error and not return any key data.
/// ```
const IV: [u8; IV_LEN] = [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6];

/// Type alias representing wrapped key roughly equivalent to `[u8; N + IV_LEN]`.
pub type KwWrappedKey<N> = Array<u8, Sum<N, IvLen>>;

/// AES Key Wrapper (KW), as defined in [RFC 3394].
///
/// [RFC 3394]: https://www.rfc-editor.org/rfc/rfc3394.txt
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AesKw<C> {
    cipher: C,
}

impl<C> InnerUser for AesKw<C> {
    type Inner = C;
}

impl<C> InnerInit for AesKw<C> {
    #[inline]
    fn inner_init(cipher: Self::Inner) -> Self {
        AesKw { cipher }
    }
}

impl<C: BlockCipherEncrypt<BlockSize = U16>> AesKw<C> {
    /// Wrap key into `buf` assuming that it has correct length.
    fn wrap_key_trusted(&self, key: &[u8], buf: &mut [u8]) {
        let blocks_len = key.len() / IV_LEN;

        // 1) Initialize variables

        // Set A to the IV
        let block = &mut Block::<C>::default();
        block[..IV_LEN].copy_from_slice(&IV);

        // 2) Calculate intermediate values
        buf[IV_LEN..].copy_from_slice(key);

        self.cipher.encrypt_with_backend(Ctx {
            blocks_len,
            block,
            buf,
        });

        // 3) Output the results
        buf[..IV_LEN].copy_from_slice(&block[..IV_LEN]);
    }

    /// Wrap `key` and write result to `buf`.
    ///
    /// Returns slice which points to `buf` and contains wrapped data.
    ///
    /// Length of `data` must be multiple of [`IV_LEN`] and bigger than zero.
    /// Length of `buf` must be bigger or equal to `data.len() + IV_LEN`.
    #[inline]
    pub fn wrap_key<'a>(&self, key: &[u8], buf: &'a mut [u8]) -> Result<&'a [u8], Error> {
        let blocks_rem = key.len() % IV_LEN;
        if blocks_rem != 0 {
            return Err(Error::InvalidDataSize);
        }

        let expected_len = key.len() + IV_LEN;
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
    /// const fn check_key_size(n: usize) -> usize {
    ///     assert!(n != 0 && n % IV_LEN == 0);
    ///     0
    /// }
    ///
    /// pub fn wrap_fixed_key<const N: usize>(
    ///     &self,
    ///     key: &[u8; N],
    /// ) -> [u8; N + IV_LEN]
    /// where
    ///     [(); check_key_size(N)]: Sized,
    /// { ... }
    /// ```
    /// but uses [`hybrid_array::Array`][Array] instead of built-in arrays
    /// to work around current limitations of the const generics system.
    #[inline]
    pub fn wrap_fixed_key<N>(&self, key: &Array<u8, N>) -> KwWrappedKey<N>
    where
        N: ArraySize + NonZero + Add<IvLen> + Rem<IvLen>,
        Sum<N, IvLen>: ArraySize,
        Mod<N, IvLen>: Zero,
    {
        let mut buf = KwWrappedKey::<N>::default();
        self.wrap_key_trusted(key, &mut buf);
        buf
    }
}

impl<C: BlockCipherDecrypt<BlockSize = U16>> AesKw<C> {
    /// Unwrap key into `buf` assuming that it has correct length.
    fn unwrap_key_trusted<'a>(
        &self,
        wkey: &[u8],
        buf: &'a mut [u8],
    ) -> Result<&'a [u8], IntegrityCheckFailed> {
        let blocks_len = buf.len() / IV_LEN;

        // 1) Initialize variables

        let block = &mut Block::<C>::default();
        block[..IV_LEN].copy_from_slice(&wkey[..IV_LEN]);

        //   for i = 1 to n: R[i] = C[i]
        buf.copy_from_slice(&wkey[IV_LEN..]);

        // 2) Calculate intermediate values

        self.cipher.decrypt_with_backend(Ctx {
            blocks_len,
            block,
            buf,
        });

        // 3) Output the results

        let expected_iv = u64::from_ne_bytes(IV);
        let calc_iv = u64::from_ne_bytes(block[..IV_LEN].try_into().unwrap());
        if calc_iv == expected_iv {
            Ok(buf)
        } else {
            buf.fill(0);
            Err(IntegrityCheckFailed)
        }
    }

    /// Unwrap `data` and write result to `buf`.
    ///
    /// Returns slice which points to `buf` and contains unwrapped data.
    ///
    /// Length of `data` must be multiple of [`IV_LEN`] and bigger than zero.
    /// Length of `buf` must be bigger or equal to `data.len()`.
    #[inline]
    pub fn unwrap_key<'a>(&self, wkey: &[u8], buf: &'a mut [u8]) -> Result<&'a [u8], Error> {
        let blocks_len = wkey.len() / IV_LEN;
        let blocks_rem = wkey.len() % IV_LEN;
        if blocks_rem != 0 || blocks_len < 1 {
            return Err(Error::InvalidDataSize);
        }

        let blocks_len = blocks_len - 1;
        let expected_len = blocks_len * IV_LEN;
        let buf = buf
            .get_mut(..expected_len)
            .ok_or(Error::InvalidOutputSize { expected_len })?;

        self.unwrap_key_trusted(wkey, buf)
            .map_err(|_| Error::IntegrityCheckFailed)?;

        Ok(buf)
    }

    /// Unwrap key in `data` and return unwrapped key.
    ///
    /// This method is roughly equivalent to:
    /// ```ignore
    /// const fn check_key_size(n: usize) -> usize {
    ///     assert!(n != 0 && n % IV_LEN == 0);
    ///     0
    /// }
    ///
    /// fn unwrap_fixed_key<const N: usize>(
    ///     &self,
    ///     data: &[u8; N + IV_LEN],
    /// ) -> [u8; N]
    /// where
    ///     [(); check_key_size(N)]: Sized,
    /// { ... }
    /// ```
    /// but uses [`hybrid_array::Array`][Array] instead of built-in arrays
    /// to work around current limitations of the const generics system.
    #[inline]
    pub fn unwrap_fixed_key<N>(
        &self,
        wkey: &KwWrappedKey<N>,
    ) -> Result<Array<u8, N>, IntegrityCheckFailed>
    where
        N: ArraySize + NonZero + Add<IvLen> + Rem<IvLen>,
        Sum<N, IvLen>: ArraySize,
        Mod<N, IvLen>: Zero,
    {
        let mut buf = Array::<u8, N>::default();
        self.unwrap_key_trusted(wkey, &mut buf)?;
        Ok(buf)
    }
}
