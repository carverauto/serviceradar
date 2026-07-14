#![no_std]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]
#![warn(missing_docs)]

pub use polyval::universal_hash;

use polyval::PolyvalGeneric;
use universal_hash::{
    KeyInit, UhfBackend, UhfClosure, UniversalHash,
    array::ArraySize,
    consts::U16,
    crypto_common::{BlockSizeUser, KeySizeUser, ParBlocksSizeUser},
    typenum::{Const, ToUInt, U},
};

#[cfg(feature = "zeroize")]
use zeroize::Zeroize;

/// GHASH keys (16-bytes)
pub type Key = universal_hash::Key<GHash>;

/// GHASH blocks (16-bytes)
pub type Block = universal_hash::Block<GHash>;

/// GHASH tags (16-bytes)
pub type Tag = universal_hash::Block<GHash>;

/// **GHASH**: universal hash over GF(2^128) used by AES-GCM.
///
/// GHASH is a universal hash function used for message authentication in
/// the AES-GCM authenticated encryption cipher.
pub type GHash = GHashGeneric<8>;

/// **GHASH**: universal hash over GF(2^128) used by AES-GCM.
///
/// GHASH is a universal hash function used for message authentication in
/// the AES-GCM authenticated encryption cipher.
///
/// Paramaterized on a constant that determines how many
/// blocks to process at once: higher numbers use more memory,
/// and require more time to re-key, but process data significantly
/// faster.
///
/// (This constant is not used when acceleration is not enabled.)
#[derive(Clone)]
pub struct GHashGeneric<const N: usize = 8>(PolyvalGeneric<N>);

impl<const N: usize> KeySizeUser for GHashGeneric<N> {
    type KeySize = U16;
}

impl<const N: usize> GHashGeneric<N> {
    /// Initialize GHASH with the given `H` field element and initial block
    #[inline]
    pub fn new_with_init_block(h: &Key, init_block: u128) -> Self {
        let mut h = *h;
        h.reverse();

        #[allow(unused_mut)]
        let mut h_polyval = polyval::mulx(&h);

        #[cfg(feature = "zeroize")]
        h.zeroize();

        #[allow(clippy::let_and_return)]
        let result = GHashGeneric(PolyvalGeneric::new_with_init_block(&h_polyval, init_block));

        #[cfg(feature = "zeroize")]
        h_polyval.zeroize();

        result
    }
}

impl<const N: usize> KeyInit for GHashGeneric<N> {
    /// Initialize GHASH with the given `H` field element
    #[inline]
    fn new(h: &Key) -> Self {
        Self::new_with_init_block(h, 0)
    }
}

struct GHashGenericBackend<'b, B: UhfBackend>(&'b mut B);

impl<B: UhfBackend> BlockSizeUser for GHashGenericBackend<'_, B> {
    type BlockSize = B::BlockSize;
}

impl<B: UhfBackend> ParBlocksSizeUser for GHashGenericBackend<'_, B> {
    type ParBlocksSize = B::ParBlocksSize;
}

impl<B: UhfBackend> UhfBackend for GHashGenericBackend<'_, B> {
    fn proc_block(&mut self, x: &universal_hash::Block<B>) {
        let mut x = x.clone();
        x.reverse();
        self.0.proc_block(&x);
    }
}

impl<const N: usize> BlockSizeUser for GHashGeneric<N> {
    type BlockSize = U16;
}

impl<const N: usize> UniversalHash for GHashGeneric<N>
where
    U<N>: ArraySize,
    Const<N>: ToUInt,
{
    fn update_with_backend(&mut self, f: impl UhfClosure<BlockSize = Self::BlockSize>) {
        struct GHashGenericClosure<C: UhfClosure>(C);

        impl<C: UhfClosure> BlockSizeUser for GHashGenericClosure<C> {
            type BlockSize = C::BlockSize;
        }

        impl<C: UhfClosure> UhfClosure for GHashGenericClosure<C> {
            fn call<B: UhfBackend<BlockSize = Self::BlockSize>>(self, backend: &mut B) {
                self.0.call(&mut GHashGenericBackend(backend));
            }
        }

        self.0.update_with_backend(GHashGenericClosure(f));
    }

    /// Get GHASH output
    #[inline]
    fn finalize(self) -> Tag {
        let mut output = self.0.finalize();
        output.reverse();
        output
    }
}

impl<const N: usize> core::fmt::Debug for GHashGeneric<N> {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> Result<(), core::fmt::Error> {
        write!(f, "GHashGeneric<{}> {{ ... }}", N)
    }
}
