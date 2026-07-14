//! Random blinding support for [`Scalar`]

use super::Scalar;
use crate::{CurveArithmetic, ops::Invert};
use core::fmt;
use group::ff::Field;
use rand_core::CryptoRng;
use subtle::CtOption;
use zeroize::Zeroize;

/// Scalar blinded with a randomly generated masking value.
///
/// This provides a randomly blinded impl of [`Invert`] which is useful for
/// e.g. ECDSA ephemeral (`k`) scalars.
///
/// It implements masked variable-time inversions using Stein's algorithm, which
/// may be helpful for performance on embedded platforms.
#[derive(Clone)]
pub struct BlindedScalar<C>
where
    C: CurveArithmetic,
{
    /// Actual scalar value.
    scalar: Scalar<C>,

    /// Mask value.
    mask: Scalar<C>,
}

impl<C: CurveArithmetic> fmt::Debug for BlindedScalar<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlindedScalar").finish_non_exhaustive()
    }
}

impl<C> BlindedScalar<C>
where
    C: CurveArithmetic,
{
    /// Create a new [`BlindedScalar`] from a scalar and a [`CryptoRng`].
    pub fn new<R: CryptoRng + ?Sized>(scalar: Scalar<C>, rng: &mut R) -> Self {
        Self {
            scalar,
            mask: Scalar::<C>::random(rng),
        }
    }
}

impl<C> AsRef<Scalar<C>> for BlindedScalar<C>
where
    C: CurveArithmetic,
{
    fn as_ref(&self) -> &Scalar<C> {
        &self.scalar
    }
}

impl<C> Invert for BlindedScalar<C>
where
    C: CurveArithmetic,
{
    type Output = CtOption<Scalar<C>>;

    fn invert(&self) -> CtOption<Scalar<C>> {
        // prevent side channel analysis of scalar inversion by pre-and-post-multiplying
        // with the random masking scalar
        (self.scalar * self.mask)
            .invert_vartime()
            .map(|s| s * self.mask)
    }
}

impl<C> Drop for BlindedScalar<C>
where
    C: CurveArithmetic,
{
    fn drop(&mut self) {
        self.scalar.zeroize();
        self.mask.zeroize();
    }
}
