//! Random number generator support

use super::Limb;
use crate::{Encoding, NonZero, Random, RandomMod};
use rand_core::TryRngCore;
use subtle::ConstantTimeLess;

impl Random for Limb {
    fn try_random<R: TryRngCore + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        #[cfg(target_pointer_width = "32")]
        let val = rng.try_next_u32()?;
        #[cfg(target_pointer_width = "64")]
        let val = rng.try_next_u64()?;

        Ok(Self(val))
    }
}

impl RandomMod for Limb {
    fn try_random_mod<R: TryRngCore + ?Sized>(
        rng: &mut R,
        modulus: &NonZero<Self>,
    ) -> Result<Self, R::Error> {
        let mut bytes = <Self as Encoding>::Repr::default();

        let n_bits = modulus.bits() as usize;
        let n_bytes = n_bits.div_ceil(8);
        let mask = 0xffu8 >> (8 * n_bytes - n_bits);

        loop {
            rng.try_fill_bytes(&mut bytes[..n_bytes])?;
            bytes[n_bytes - 1] &= mask;

            let n = Limb::from_le_bytes(bytes);
            if n.ct_lt(modulus).into() {
                return Ok(n);
            }
        }
    }
}
