//! Const-friendly decoding/encoding operations for [`Int`].

use crate::{Int, Uint};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Create a new [`Int`] from the provided big endian hex string.
    ///
    /// Panics if the hex is malformed or not zero-padded accordingly for the size.
    ///
    /// See [`Uint::from_be_hex`] for more details.
    pub const fn from_be_hex(hex: &str) -> Self {
        Self(Uint::from_be_hex(hex))
    }
}
