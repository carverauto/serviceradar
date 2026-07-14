//! Public key recovery support.

use crate::{Error, Result};

#[cfg(feature = "signing")]
use {
    crate::{SigningKey, hazmat::sign_prehashed_rfc6979},
    elliptic_curve::{FieldBytes, subtle::CtOption},
    signature::{
        DigestSigner, MultipartSigner, RandomizedDigestSigner, Signer,
        digest::{FixedOutput, Update},
        hazmat::{PrehashSigner, RandomizedPrehashSigner},
        rand_core::TryCryptoRng,
    },
};

#[cfg(feature = "verifying")]
use {
    crate::{VerifyingKey, hazmat::verify_prehashed},
    elliptic_curve::{
        AffinePoint, FieldBytesEncoding, FieldBytesSize, Group, PrimeField, ProjectivePoint,
        bigint::CheckedAdd,
        ops::{LinearCombination, Reduce},
        point::DecompressPoint,
        sec1::{self, FromEncodedPoint, ToEncodedPoint},
    },
};

#[cfg(any(feature = "signing", feature = "verifying"))]
use {
    crate::{
        EcdsaCurve, Signature, SignatureSize,
        hazmat::{DigestAlgorithm, bits2field},
    },
    elliptic_curve::{CurveArithmetic, Scalar, array::ArraySize, ops::Invert},
    signature::digest::Digest,
};

/// Recovery IDs, a.k.a. "recid".
///
/// This is an integer value `0`, `1`, `2`, or `3` included along with a
/// signature which is used during the recovery process to select the correct
/// public key from the signature.
///
/// It consists of two bits of information:
///
/// - low bit (0/1): was the y-coordinate of the affine point resulting from
///   the fixed-base multiplication 𝑘×𝑮 odd? This part of the algorithm
///   functions similar to point decompression.
/// - hi bit (2/3): did the affine x-coordinate of 𝑘×𝑮 overflow the order of
///   the scalar field, requiring a reduction when computing `r`?
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
pub struct RecoveryId(pub(crate) u8);

impl RecoveryId {
    /// Maximum supported value for the recovery ID (inclusive).
    pub const MAX: u8 = 3;

    /// Create a new [`RecoveryId`] from the following 1-bit arguments:
    ///
    /// - `is_y_odd`: is the affine y-coordinate of 𝑘×𝑮 odd?
    /// - `is_x_reduced`: did the affine x-coordinate of 𝑘×𝑮 overflow the curve order?
    pub const fn new(is_y_odd: bool, is_x_reduced: bool) -> Self {
        Self(((is_x_reduced as u8) << 1) | (is_y_odd as u8))
    }

    /// Did the affine x-coordinate of 𝑘×𝑮 overflow the curve order?
    pub const fn is_x_reduced(self) -> bool {
        (self.0 & 0b10) != 0
    }

    /// Is the affine y-coordinate of 𝑘×𝑮 odd?
    pub const fn is_y_odd(self) -> bool {
        (self.0 & 1) != 0
    }

    /// Convert a `u8` into a [`RecoveryId`].
    pub const fn from_byte(byte: u8) -> Option<Self> {
        if byte <= Self::MAX {
            Some(Self(byte))
        } else {
            None
        }
    }

    /// Convert this [`RecoveryId`] into a `u8`.
    pub const fn to_byte(self) -> u8 {
        self.0
    }
}

#[cfg(feature = "verifying")]
impl RecoveryId {
    /// Given a public key, message, and signature, use trial recovery
    /// to determine if a suitable recovery ID exists, or return an error
    /// otherwise.
    pub fn trial_recovery_from_msg<C>(
        verifying_key: &VerifyingKey<C>,
        msg: &[u8],
        signature: &Signature<C>,
    ) -> Result<Self>
    where
        C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
        AffinePoint<C>: DecompressPoint<C> + FromEncodedPoint<C> + ToEncodedPoint<C>,
        FieldBytesSize<C>: sec1::ModulusSize,
        SignatureSize<C>: ArraySize,
    {
        Self::trial_recovery_from_digest(verifying_key, C::Digest::new_with_prefix(msg), signature)
    }

    /// Given a public key, message digest, and signature, use trial recovery
    /// to determine if a suitable recovery ID exists, or return an error
    /// otherwise.
    pub fn trial_recovery_from_digest<C, D>(
        verifying_key: &VerifyingKey<C>,
        digest: D,
        signature: &Signature<C>,
    ) -> Result<Self>
    where
        C: EcdsaCurve + CurveArithmetic,
        D: Digest,
        AffinePoint<C>: DecompressPoint<C> + FromEncodedPoint<C> + ToEncodedPoint<C>,
        FieldBytesSize<C>: sec1::ModulusSize,
        SignatureSize<C>: ArraySize,
    {
        Self::trial_recovery_from_prehash(verifying_key, &digest.finalize(), signature)
    }

    /// Given a public key, message digest, and signature, use trial recovery
    /// to determine if a suitable recovery ID exists, or return an error
    /// otherwise.
    pub fn trial_recovery_from_prehash<C>(
        verifying_key: &VerifyingKey<C>,
        prehash: &[u8],
        signature: &Signature<C>,
    ) -> Result<Self>
    where
        C: EcdsaCurve + CurveArithmetic,
        AffinePoint<C>: DecompressPoint<C> + FromEncodedPoint<C> + ToEncodedPoint<C>,
        FieldBytesSize<C>: sec1::ModulusSize,
        SignatureSize<C>: ArraySize,
    {
        // Ensure signature verifies with the recovered key
        verify_prehashed::<C>(
            &ProjectivePoint::<C>::from(*verifying_key.as_affine()),
            &bits2field::<C>(prehash)?,
            signature,
        )?;
        for id in 0..=Self::MAX {
            let recovery_id = RecoveryId(id);

            if let Ok(vk) =
                VerifyingKey::recover_from_prehash_noverify(prehash, signature, recovery_id)
            {
                if verifying_key == &vk {
                    return Ok(recovery_id);
                }
            }
        }

        Err(Error::new())
    }
}

impl TryFrom<u8> for RecoveryId {
    type Error = Error;

    fn try_from(byte: u8) -> Result<Self> {
        Self::from_byte(byte).ok_or_else(Error::new)
    }
}

impl From<RecoveryId> for u8 {
    fn from(id: RecoveryId) -> u8 {
        id.0
    }
}

#[cfg(feature = "signing")]
impl<C> SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    /// Sign the given message prehash, using the given rng for the RFC6979 Section 3.6 "additional
    /// data", returning a signature and recovery ID.
    pub fn sign_prehash_recoverable_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        prehash: &[u8],
    ) -> Result<(Signature<C>, RecoveryId)> {
        let z = bits2field::<C>(prehash)?;

        loop {
            let mut ad = FieldBytes::<C>::default();
            rng.try_fill_bytes(&mut ad).map_err(|_| Error::new())?;

            if let Ok(result) =
                sign_prehashed_rfc6979::<C, C::Digest>(self.as_nonzero_scalar(), &z, &ad)
            {
                break Ok(result);
            }
        }
    }

    /// Sign the given message prehash, returning a signature and recovery ID.
    pub fn sign_prehash_recoverable(&self, prehash: &[u8]) -> Result<(Signature<C>, RecoveryId)> {
        let z = bits2field::<C>(prehash)?;
        sign_prehashed_rfc6979::<C, C::Digest>(self.as_nonzero_scalar(), &z, &[])
    }

    /// Sign the given message digest, returning a signature and recovery ID.
    pub fn sign_digest_recoverable<D>(&self, msg_digest: D) -> Result<(Signature<C>, RecoveryId)>
    where
        D: Digest,
    {
        self.sign_prehash_recoverable(&msg_digest.finalize())
    }

    /// Sign the given message, hashing it with the curve's default digest
    /// function, and returning a signature and recovery ID.
    pub fn sign_recoverable(&self, msg: &[u8]) -> Result<(Signature<C>, RecoveryId)> {
        self.sign_digest_recoverable(C::Digest::new_with_prefix(msg))
    }
}

#[cfg(feature = "signing")]
impl<C, D> DigestSigner<D, (Signature<C>, RecoveryId)> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    D: Digest + Update,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign_digest<F: Fn(&mut D) -> Result<()>>(
        &self,
        f: F,
    ) -> Result<(Signature<C>, RecoveryId)> {
        let mut digest = D::new();
        f(&mut digest)?;
        self.sign_digest_recoverable(digest)
    }
}

#[cfg(feature = "signing")]
impl<C> RandomizedPrehashSigner<(Signature<C>, RecoveryId)> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn sign_prehash_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        prehash: &[u8],
    ) -> Result<(Signature<C>, RecoveryId)> {
        self.sign_prehash_recoverable_with_rng(rng, prehash)
    }
}

#[cfg(feature = "signing")]
impl<C, D> RandomizedDigestSigner<D, (Signature<C>, RecoveryId)> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    D: Digest + FixedOutput,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign_digest_with_rng<R: TryCryptoRng + ?Sized, F: Fn(&mut D) -> Result<()>>(
        &self,
        rng: &mut R,
        f: F,
    ) -> Result<(Signature<C>, RecoveryId)> {
        let mut digest = D::new();
        f(&mut digest)?;
        self.sign_prehash_with_rng(rng, &digest.finalize_fixed())
    }
}

#[cfg(feature = "signing")]
impl<C> PrehashSigner<(Signature<C>, RecoveryId)> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn sign_prehash(&self, prehash: &[u8]) -> Result<(Signature<C>, RecoveryId)> {
        self.sign_prehash_recoverable(prehash)
    }
}

#[cfg(feature = "signing")]
impl<C> Signer<(Signature<C>, RecoveryId)> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign(&self, msg: &[u8]) -> Result<(Signature<C>, RecoveryId)> {
        self.try_multipart_sign(&[msg])
    }
}

#[cfg(feature = "signing")]
impl<C> MultipartSigner<(Signature<C>, RecoveryId)> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_multipart_sign(&self, msg: &[&[u8]]) -> Result<(Signature<C>, RecoveryId)> {
        let mut digest = C::Digest::new();
        msg.iter()
            .for_each(|slice| Digest::update(&mut digest, slice));
        self.sign_digest_recoverable(digest)
    }
}

#[cfg(feature = "verifying")]
impl<C> VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    AffinePoint<C>: DecompressPoint<C> + FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
    SignatureSize<C>: ArraySize,
{
    /// Recover a [`VerifyingKey`] from the given message, signature, and
    /// [`RecoveryId`].
    ///
    /// The message is first hashed using this curve's [`DigestAlgorithm`].
    pub fn recover_from_msg(
        msg: &[u8],
        signature: &Signature<C>,
        recovery_id: RecoveryId,
    ) -> Result<Self>
    where
        C: DigestAlgorithm,
    {
        Self::recover_from_digest(C::Digest::new_with_prefix(msg), signature, recovery_id)
    }

    /// Recover a [`VerifyingKey`] from the given message [`Digest`],
    /// signature, and [`RecoveryId`].
    pub fn recover_from_digest<D>(
        msg_digest: D,
        signature: &Signature<C>,
        recovery_id: RecoveryId,
    ) -> Result<Self>
    where
        D: Digest,
    {
        Self::recover_from_prehash(&msg_digest.finalize(), signature, recovery_id)
    }

    /// Recover a [`VerifyingKey`] from the given `prehash` of a message, the
    /// signature over that prehashed message, and a [`RecoveryId`].
    pub fn recover_from_prehash(
        prehash: &[u8],
        signature: &Signature<C>,
        recovery_id: RecoveryId,
    ) -> Result<Self> {
        let vk = Self::recover_from_prehash_noverify(prehash, signature, recovery_id)?;
        // Ensure signature verifies with the recovered key
        verify_prehashed::<C>(
            &ProjectivePoint::<C>::from(*vk.as_affine()),
            &bits2field::<C>(prehash)?,
            signature,
        )?;
        Ok(vk)
    }

    /// Recover a [`VerifyingKey`] from the given `prehash` of a message, the
    /// signature over that prehashed message, and a [`RecoveryId`]. Compared to
    /// `recover_from_prehash`, this function skips verification with the
    /// recovered key.
    #[allow(non_snake_case)]
    pub fn recover_from_prehash_noverify(
        prehash: &[u8],
        signature: &Signature<C>,
        recovery_id: RecoveryId,
    ) -> Result<Self> {
        let (r, s) = signature.split_scalars();
        let z = Scalar::<C>::reduce(&bits2field::<C>(prehash)?);

        let r_bytes = if recovery_id.is_x_reduced() {
            C::Uint::decode_field_bytes(&r.to_repr())
                .checked_add(&C::ORDER)
                .into_option()
                .ok_or_else(Error::new)?
                .encode_field_bytes()
        } else {
            r.to_repr()
        };

        let R: ProjectivePoint<C> =
            AffinePoint::<C>::decompress(&r_bytes, u8::from(recovery_id.is_y_odd()).into())
                .into_option()
                .ok_or_else(Error::new)?
                .into();

        let r_inv = *r.invert();
        let u1 = -(r_inv * z);
        let u2 = r_inv * *s;
        let pk = ProjectivePoint::<C>::lincomb(&[(ProjectivePoint::<C>::generator(), u1), (R, u2)]);
        Self::from_affine(pk.into())
    }
}

#[cfg(test)]
mod tests {
    use super::RecoveryId;

    #[test]
    fn new() {
        assert_eq!(RecoveryId::new(false, false).to_byte(), 0);
        assert_eq!(RecoveryId::new(true, false).to_byte(), 1);
        assert_eq!(RecoveryId::new(false, true).to_byte(), 2);
        assert_eq!(RecoveryId::new(true, true).to_byte(), 3);
    }

    #[test]
    fn try_from() {
        for n in 0u8..=3 {
            assert_eq!(RecoveryId::try_from(n).expect("RecoveryId").to_byte(), n);
        }

        for n in 4u8..=255 {
            assert!(RecoveryId::try_from(n).is_err());
        }
    }

    #[test]
    fn is_x_reduced() {
        assert!(!RecoveryId::try_from(0).expect("RecoveryId").is_x_reduced());
        assert!(!RecoveryId::try_from(1).expect("RecoveryId").is_x_reduced());
        assert!(RecoveryId::try_from(2).expect("RecoveryId").is_x_reduced());
        assert!(RecoveryId::try_from(3).expect("RecoveryId").is_x_reduced());
    }

    #[test]
    fn is_y_odd() {
        assert!(!RecoveryId::try_from(0).expect("RecoveryId").is_y_odd());
        assert!(RecoveryId::try_from(1).expect("RecoveryId").is_y_odd());
        assert!(!RecoveryId::try_from(2).expect("RecoveryId").is_y_odd());
        assert!(RecoveryId::try_from(3).expect("RecoveryId").is_y_odd());
    }
}
