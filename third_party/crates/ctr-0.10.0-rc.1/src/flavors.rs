//! CTR mode flavors

use cipher::{
    StreamCipherCounter,
    array::{Array, ArraySize},
};

mod ctr128;
mod ctr32;
mod ctr64;

pub use ctr32::{Ctr32BE, Ctr32LE};
pub use ctr64::{Ctr64BE, Ctr64LE};
pub use ctr128::{Ctr128BE, Ctr128LE};

/// Trait implemented by different CTR flavors.
pub trait CtrFlavor<B: ArraySize> {
    /// Inner representation of nonce.
    type CtrNonce: Clone;
    /// Backend numeric type
    type Backend: StreamCipherCounter;
    /// Flavor name
    const NAME: &'static str;

    /// Return number of remaining blocks.
    ///
    /// If result does not fit into `usize`, returns `None`.
    fn remaining(cn: &Self::CtrNonce) -> Option<usize>;

    /// Generate block for given `nonce` and current counter value.
    fn next_block(cn: &mut Self::CtrNonce) -> Array<u8, B>;

    /// Generate block for given `nonce` and current counter value.
    fn current_block(cn: &Self::CtrNonce) -> Array<u8, B>;

    /// Initialize from bytes.
    fn from_nonce(block: &Array<u8, B>) -> Self::CtrNonce;

    /// Convert from a backend value
    fn set_from_backend(cn: &mut Self::CtrNonce, v: Self::Backend);

    /// Convert to a backend value
    fn as_backend(cn: &Self::CtrNonce) -> Self::Backend;
}
