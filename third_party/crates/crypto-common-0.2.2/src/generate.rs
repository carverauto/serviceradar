use hybrid_array::{Array, ArraySize};
use rand_core::{CryptoRng, TryCryptoRng};

#[cfg(feature = "getrandom")]
use getrandom::{SysRng, rand_core::UnwrapErr};

/// Secure random generation.
pub trait Generate: Sized {
    /// Generate random key using the provided [`TryCryptoRng`].
    ///
    /// # Errors
    /// Returns `R::Error` in the event the provided RNG `R` experiences an internal failure.
    fn try_generate_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error>;

    /// Generate random key using the provided [`CryptoRng`].
    #[must_use]
    fn generate_from_rng<R: CryptoRng + ?Sized>(rng: &mut R) -> Self {
        let Ok(ret) = Self::try_generate_from_rng(rng);
        ret
    }

    /// Randomly generate a value of this type using the system's ambient cryptographically secure
    /// random number generator.
    ///
    /// # Errors
    /// Returns [`getrandom::Error`] in the event the system's ambient RNG experiences an internal
    /// failure.
    #[cfg(feature = "getrandom")]
    fn try_generate() -> Result<Self, getrandom::Error> {
        Self::try_generate_from_rng(&mut SysRng)
    }

    /// Randomly generate a value of this type using the system's ambient cryptographically secure
    /// random number generator.
    ///
    /// # Panics
    /// This method will panic in the event the system's ambient RNG experiences an internal
    /// failure.
    ///
    /// This shouldn't happen on most modern operating systems.
    #[cfg(feature = "getrandom")]
    #[must_use]
    fn generate() -> Self {
        Self::generate_from_rng(&mut UnwrapErr(SysRng))
    }
}

impl Generate for u32 {
    #[inline]
    fn try_generate_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        rng.try_next_u32()
    }
}

impl Generate for u64 {
    #[inline]
    fn try_generate_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        rng.try_next_u64()
    }
}

impl<const N: usize> Generate for [u8; N] {
    #[inline]
    fn try_generate_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        let mut ret = [0u8; N];
        rng.try_fill_bytes(&mut ret)?;
        Ok(ret)
    }
}

impl<U: ArraySize> Generate for Array<u8, U> {
    #[inline]
    fn try_generate_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        let mut ret = Self::default();
        rng.try_fill_bytes(&mut ret)?;
        Ok(ret)
    }
}

impl<U: ArraySize> Generate for Array<u32, U> {
    #[inline]
    fn try_generate_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        Self::try_from_fn(|_| rng.try_next_u32())
    }
}

impl<U: ArraySize> Generate for Array<u64, U> {
    #[inline]
    fn try_generate_from_rng<R: TryCryptoRng + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        Self::try_from_fn(|_| rng.try_next_u64())
    }
}
