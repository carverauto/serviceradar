#![no_std]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub use hmac;

use core::fmt;
use core::marker::PhantomData;
use hmac::digest::{
    Output, OutputSizeUser, array::typenum::Unsigned, crypto_common::AlgorithmName,
};
use hmac::{Hmac, SimpleHmac};

mod errors;
mod sealed;

pub use errors::{InvalidLength, InvalidPrkLength};

/// [`HkdfExtract`] variant which uses [`SimpleHmac`] for underlying HMAC
/// implementation.
pub type SimpleHkdfExtract<H> = HkdfExtract<H, SimpleHmac<H>>;
/// [`Hkdf`] variant which uses [`SimpleHmac`] for underlying HMAC
/// implementation.
pub type SimpleHkdf<H> = Hkdf<H, SimpleHmac<H>>;

/// Structure representing the streaming context of an HKDF-Extract operation
/// ```rust
/// # use hkdf::{Hkdf, HkdfExtract};
/// # use sha2::Sha256;
/// let mut extract_ctx = HkdfExtract::<Sha256>::new(Some(b"mysalt"));
/// extract_ctx.input_ikm(b"hello");
/// extract_ctx.input_ikm(b" world");
/// let (streamed_res, _) = extract_ctx.finalize();
///
/// let (oneshot_res, _) = Hkdf::<Sha256>::extract(Some(b"mysalt"), b"hello world");
/// assert_eq!(streamed_res, oneshot_res);
/// ```
#[derive(Clone)]
pub struct HkdfExtract<H, I = Hmac<H>>
where
    H: OutputSizeUser,
    I: HmacImpl<H>,
{
    hmac: I,
    _pd: PhantomData<H>,
}

impl<H, I> HkdfExtract<H, I>
where
    H: OutputSizeUser,
    I: HmacImpl<H>,
{
    /// Initiates the HKDF-Extract context with the given optional salt
    pub fn new(salt: Option<&[u8]>) -> Self {
        let default_salt = Output::<H>::default();
        let salt = salt.unwrap_or(&default_salt);
        Self {
            hmac: I::new_from_slice(salt),
            _pd: PhantomData,
        }
    }

    /// Feeds in additional input key material to the HKDF-Extract context
    pub fn input_ikm(&mut self, ikm: &[u8]) {
        self.hmac.update(ikm);
    }

    /// Completes the HKDF-Extract operation, returning both the generated pseudorandom key and
    /// `Hkdf` struct for expanding.
    pub fn finalize(self) -> (Output<H>, Hkdf<H, I>) {
        let prk = self.hmac.finalize();
        let hkdf = Hkdf::from_prk(&prk).expect("PRK size is correct");
        (prk, hkdf)
    }
}

impl<H, I> fmt::Debug for HkdfExtract<H, I>
where
    H: OutputSizeUser,
    I: HmacImpl<H> + AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("HkdfExtract<")?;
        <I as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

/// Structure representing the HKDF, capable of HKDF-Expand and HKDF-Extract operations.
/// Recommendations for the correct usage of the parameters can be found in the
/// [crate root](index.html#usage).
#[derive(Clone)]
pub struct Hkdf<H: OutputSizeUser, I: HmacImpl<H> = Hmac<H>> {
    hmac: I,
    _pd: PhantomData<H>,
}

impl<H: OutputSizeUser, I: HmacImpl<H>> Hkdf<H, I> {
    /// Convenience method for [`extract`][Hkdf::extract] when the generated
    /// pseudorandom key can be ignored and only HKDF-Expand operation is needed. This is the most
    /// common constructor.
    pub fn new(salt: Option<&[u8]>, ikm: &[u8]) -> Self {
        let (_, hkdf) = Self::extract(salt, ikm);
        hkdf
    }

    /// Create `Hkdf` from an already cryptographically strong pseudorandom key
    /// as per section 3.3 from RFC5869.
    pub fn from_prk(prk: &[u8]) -> Result<Self, InvalidPrkLength> {
        // section 2.3 specifies that prk must be "at least HashLen octets"
        if prk.len() < <H as OutputSizeUser>::OutputSize::to_usize() {
            return Err(InvalidPrkLength);
        }
        Ok(Self {
            hmac: I::new_from_slice(prk),
            _pd: PhantomData,
        })
    }

    /// The RFC5869 HKDF-Extract operation returning both the generated
    /// pseudorandom key and `Hkdf` struct for expanding.
    pub fn extract(salt: Option<&[u8]>, ikm: &[u8]) -> (Output<H>, Self) {
        let mut extract_ctx = HkdfExtract::new(salt);
        extract_ctx.input_ikm(ikm);
        extract_ctx.finalize()
    }

    /// The RFC5869 HKDF-Expand operation. This is equivalent to calling
    /// [`expand`][Hkdf::extract] with the `info` argument set equal to the
    /// concatenation of all the elements of `info_components`.
    pub fn expand_multi_info(
        &self,
        info_components: &[&[u8]],
        okm: &mut [u8],
    ) -> Result<(), InvalidLength> {
        let mut prev: Option<Output<H>> = None;

        let chunk_len = <H as OutputSizeUser>::OutputSize::USIZE;
        if okm.len() > chunk_len * 255 {
            return Err(InvalidLength);
        }

        for (block_n, block) in okm.chunks_mut(chunk_len).enumerate() {
            let mut hmac = self.hmac.clone();

            if let Some(ref prev) = prev {
                hmac.update(prev)
            };

            // Feed in the info components in sequence. This is equivalent to feeding in the
            // concatenation of all the info components
            for info in info_components {
                hmac.update(info);
            }

            hmac.update(&[block_n as u8 + 1]);

            let output = hmac.finalize();

            let block_len = block.len();
            block.copy_from_slice(&output[..block_len]);

            prev = Some(output);
        }

        Ok(())
    }

    /// The RFC5869 HKDF-Expand operation
    ///
    /// If you don't have any `info` to pass, use an empty slice.
    pub fn expand(&self, info: &[u8], okm: &mut [u8]) -> Result<(), InvalidLength> {
        self.expand_multi_info(&[info], okm)
    }
}

impl<H, I> fmt::Debug for Hkdf<H, I>
where
    H: OutputSizeUser,
    I: HmacImpl<H>,
    I: AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Hkdf<")?;
        <I as AlgorithmName>::write_alg_name(f)?;
        f.write_str("> { ... }")
    }
}

/// Sealed trait implemented for [`Hmac`] and [`SimpleHmac`].
pub trait HmacImpl<H: OutputSizeUser>: sealed::Sealed<H> + Clone {}

impl<H: OutputSizeUser, T: sealed::Sealed<H> + Clone> HmacImpl<H> for T {}
