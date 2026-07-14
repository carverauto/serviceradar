//! Random number generator support

use rand_core::TryRngCore;

use crate::{Int, Random, RandomBits, RandomBitsError};

use super::Uint;

impl<const LIMBS: usize> Random for Int<LIMBS> {
    /// Generate a cryptographically secure random [`Int`].
    fn try_random<R: TryRngCore + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        Ok(Self(Uint::try_random(rng)?))
    }
}

impl<const LIMBS: usize> RandomBits for Int<LIMBS> {
    fn try_random_bits<R: TryRngCore + ?Sized>(
        rng: &mut R,
        bit_length: u32,
    ) -> Result<Self, RandomBitsError<R::Error>> {
        Self::try_random_bits_with_precision(rng, bit_length, Self::BITS)
    }

    fn try_random_bits_with_precision<R: TryRngCore + ?Sized>(
        rng: &mut R,
        bit_length: u32,
        bits_precision: u32,
    ) -> Result<Self, RandomBitsError<R::Error>> {
        Uint::try_random_bits_with_precision(rng, bit_length, bits_precision).map(Self)
    }
}
