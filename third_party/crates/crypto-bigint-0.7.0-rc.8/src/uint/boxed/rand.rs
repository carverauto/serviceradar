//! Random number generator support.

use super::BoxedUint;
use crate::{
    NonZero, RandomBits, RandomBitsError, RandomMod,
    uint::rand::{random_bits_core, random_mod_core},
};
use rand_core::{RngCore, TryRngCore};

impl RandomBits for BoxedUint {
    fn try_random_bits<R: TryRngCore + ?Sized>(
        rng: &mut R,
        bit_length: u32,
    ) -> Result<Self, RandomBitsError<R::Error>> {
        Self::try_random_bits_with_precision(rng, bit_length, bit_length)
    }

    fn try_random_bits_with_precision<R: TryRngCore + ?Sized>(
        rng: &mut R,
        bit_length: u32,
        bits_precision: u32,
    ) -> Result<Self, RandomBitsError<R::Error>> {
        if bit_length > bits_precision {
            return Err(RandomBitsError::BitLengthTooLarge {
                bit_length,
                bits_precision,
            });
        }

        let mut ret = BoxedUint::zero_with_precision(bits_precision);
        random_bits_core(rng, &mut ret.limbs, bit_length)?;
        Ok(ret)
    }
}

impl RandomMod for BoxedUint {
    fn random_mod<R: RngCore + ?Sized>(rng: &mut R, modulus: &NonZero<Self>) -> Self {
        let mut n = BoxedUint::zero_with_precision(modulus.bits_precision());
        let Ok(()) = random_mod_core(rng, &mut n, modulus, modulus.bits());
        n
    }

    fn try_random_mod<R: TryRngCore + ?Sized>(
        rng: &mut R,
        modulus: &NonZero<Self>,
    ) -> Result<Self, R::Error> {
        let mut n = BoxedUint::zero_with_precision(modulus.bits_precision());
        random_mod_core(rng, &mut n, modulus, modulus.bits())?;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use crate::{BoxedUint, NonZero, RandomBits, RandomMod};
    use rand_core::SeedableRng;

    #[test]
    fn random() {
        let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);

        let r = BoxedUint::random_bits(&mut rng, 256);
        assert!(r.bits_precision() == 256);

        let r = BoxedUint::random_bits(&mut rng, 256 - 32 + 1);
        assert!(r.bits_precision() == 256);
        assert!(r < BoxedUint::one_with_precision(256) << (256 - 32 + 1));
    }

    #[test]
    fn random_mod() {
        let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);

        // Ensure `random_mod` runs in a reasonable amount of time
        let modulus = NonZero::new(BoxedUint::from(42u8)).unwrap();
        let res = BoxedUint::random_mod(&mut rng, &modulus);

        // Check that the value is in range
        assert!(res < BoxedUint::from(42u8));

        // Ensure `random_mod` runs in a reasonable amount of time
        // when the modulus is larger than 1 limb
        let modulus = NonZero::new(BoxedUint::from(0x10000000000000001u128)).unwrap();
        let res = BoxedUint::random_mod(&mut rng, &modulus);

        // Check that the value is in range
        assert!(res < BoxedUint::from(0x10000000000000001u128));
    }
}
