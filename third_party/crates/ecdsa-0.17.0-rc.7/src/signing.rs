//! ECDSA signing: producing signatures using a [`SigningKey`].

use crate::{
    EcdsaCurve, Error, Result, Signature, SignatureSize, SignatureWithOid, ecdsa_oid_for_digest,
    hazmat::{DigestAlgorithm, bits2field, sign_prehashed_rfc6979},
};
use core::fmt::{self, Debug};
use digest::{Digest, FixedOutput, const_oid::AssociatedOid};
use elliptic_curve::{
    CurveArithmetic, FieldBytes, NonZeroScalar, Scalar, SecretKey,
    array::ArraySize,
    group::ff::PrimeField,
    ops::Invert,
    subtle::{Choice, ConstantTimeEq, CtOption},
    zeroize::{Zeroize, ZeroizeOnDrop},
};
use signature::{
    DigestSigner, MultipartSigner, RandomizedDigestSigner, RandomizedMultipartSigner,
    RandomizedSigner, Signer,
    hazmat::{PrehashSigner, RandomizedPrehashSigner},
    rand_core::{CryptoRng, TryCryptoRng},
};

#[cfg(feature = "der")]
use {crate::der, core::ops::Add, elliptic_curve::FieldBytesSize};

#[cfg(feature = "pem")]
use {core::str::FromStr, elliptic_curve::pkcs8::DecodePrivateKey};

#[cfg(feature = "pkcs8")]
use crate::elliptic_curve::{
    AffinePoint,
    pkcs8::{
        self, ObjectIdentifier,
        der::AnyRef,
        spki::{AlgorithmIdentifier, AssociatedAlgorithmIdentifier, SignatureAlgorithmIdentifier},
    },
    sec1::{self, FromEncodedPoint, ToEncodedPoint},
};

#[cfg(feature = "verifying")]
use {crate::VerifyingKey, elliptic_curve::PublicKey, signature::KeypairRef};

#[cfg(all(feature = "alloc", feature = "pkcs8"))]
use elliptic_curve::pkcs8::{EncodePrivateKey, SecretDocument};

/// ECDSA secret key used for signing. Generic over prime order elliptic curves
/// (e.g. NIST P-curves).
///
/// Requires an [`elliptic_curve::CurveArithmetic`] impl on the curve.
///
/// ## Usage
///
/// The [`signature`] crate defines the following traits which are the
/// primary API for signing:
///
/// - [`Signer`]: sign a message using this key
/// - [`DigestSigner`]: sign the output of a [`Digest`] using this key
/// - [`PrehashSigner`]: sign the low-level raw output bytes of a message digest
///
/// See the [`p256` crate](https://docs.rs/p256/latest/p256/ecdsa/index.html)
/// for examples of using this type with a concrete elliptic curve.
#[derive(Clone)]
pub struct SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    /// ECDSA signing keys are non-zero elements of a given curve's scalar field.
    secret_scalar: NonZeroScalar<C>,

    /// Verifying key which corresponds to this signing key.
    #[cfg(feature = "verifying")]
    verifying_key: VerifyingKey<C>,
}

impl<C> SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    /// Generate a cryptographically random [`SigningKey`].
    pub fn random<R: CryptoRng + ?Sized>(rng: &mut R) -> Self {
        NonZeroScalar::<C>::random(rng).into()
    }

    /// Generate a cryptographically random [`SigningKey`].
    pub fn try_from_rng<R: TryCryptoRng + ?Sized>(
        rng: &mut R,
    ) -> core::result::Result<Self, R::Error> {
        Ok(NonZeroScalar::<C>::try_from_rng(rng)?.into())
    }

    /// Initialize signing key from a raw scalar serialized as a byte array.
    pub fn from_bytes(bytes: &FieldBytes<C>) -> Result<Self> {
        SecretKey::<C>::from_bytes(bytes)
            .map(Into::into)
            .map_err(|_| Error::new())
    }

    /// Initialize signing key from a raw scalar serialized as a byte slice.
    pub fn from_slice(bytes: &[u8]) -> Result<Self> {
        SecretKey::<C>::from_slice(bytes)
            .map(Into::into)
            .map_err(|_| Error::new())
    }

    /// Serialize this [`SigningKey`] as bytes
    pub fn to_bytes(&self) -> FieldBytes<C> {
        self.secret_scalar.to_repr()
    }

    /// Borrow the secret [`NonZeroScalar`] value for this key.
    ///
    /// # ⚠️ Warning
    ///
    /// This value is key material.
    ///
    /// Please treat it with the care it deserves!
    pub fn as_nonzero_scalar(&self) -> &NonZeroScalar<C> {
        &self.secret_scalar
    }

    /// Get the [`VerifyingKey`] which corresponds to this [`SigningKey`].
    #[cfg(feature = "verifying")]
    pub fn verifying_key(&self) -> &VerifyingKey<C> {
        &self.verifying_key
    }
}

//
// `*Signer` trait impls
//

/// Sign message digest using a deterministic ephemeral scalar (`k`)
/// computed using the algorithm described in [RFC6979 § 3.2].
///
/// [RFC6979 § 3.2]: https://tools.ietf.org/html/rfc6979#section-3
impl<C, D> DigestSigner<D, Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    D: Digest + FixedOutput,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign_digest<F: Fn(&mut D) -> Result<()>>(&self, f: F) -> Result<Signature<C>> {
        let mut digest = D::new();
        f(&mut digest)?;
        self.sign_prehash(&digest.finalize_fixed())
    }
}

/// Sign message prehash using a deterministic ephemeral scalar (`k`)
/// computed using the algorithm described in [RFC6979 § 3.2].
///
/// [RFC6979 § 3.2]: https://tools.ietf.org/html/rfc6979#section-3
impl<C> PrehashSigner<Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn sign_prehash(&self, prehash: &[u8]) -> Result<Signature<C>> {
        let z = bits2field::<C>(prehash)?;
        Ok(sign_prehashed_rfc6979::<C, C::Digest>(&self.secret_scalar, &z, &[])?.0)
    }
}

/// Sign message using a deterministic ephemeral scalar (`k`)
/// computed using the algorithm described in [RFC6979 § 3.2].
///
/// [RFC6979 § 3.2]: https://tools.ietf.org/html/rfc6979#section-3
impl<C> Signer<Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign(&self, msg: &[u8]) -> Result<Signature<C>> {
        self.try_multipart_sign(&[msg])
    }
}

impl<C> MultipartSigner<Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_multipart_sign(&self, msg: &[&[u8]]) -> core::result::Result<Signature<C>, Error> {
        self.try_sign_digest(|digest: &mut C::Digest| {
            msg.iter().for_each(|slice| digest.update(slice));
            Ok(())
        })
    }
}

impl<C, D> RandomizedDigestSigner<D, Signature<C>> for SigningKey<C>
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
    ) -> Result<Signature<C>> {
        let mut digest = D::new();
        f(&mut digest)?;
        self.sign_prehash_with_rng(rng, &digest.finalize_fixed())
    }
}

impl<C> RandomizedPrehashSigner<Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn sign_prehash_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        prehash: &[u8],
    ) -> Result<Signature<C>> {
        let z = bits2field::<C>(prehash)?;

        loop {
            let mut ad = FieldBytes::<C>::default();
            rng.try_fill_bytes(&mut ad).map_err(|_| Error::new())?;

            if let Ok((signature, _)) =
                sign_prehashed_rfc6979::<C, C::Digest>(&self.secret_scalar, &z, &ad)
            {
                break Ok(signature);
            }
        }
    }
}

impl<C> RandomizedSigner<Signature<C>> for SigningKey<C>
where
    Self: RandomizedDigestSigner<C::Digest, Signature<C>>,
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        msg: &[u8],
    ) -> Result<Signature<C>> {
        self.try_multipart_sign_with_rng(rng, &[msg])
    }
}

impl<C> RandomizedMultipartSigner<Signature<C>> for SigningKey<C>
where
    Self: RandomizedDigestSigner<C::Digest, Signature<C>>,
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_multipart_sign_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        msg: &[&[u8]],
    ) -> Result<Signature<C>> {
        self.try_sign_digest_with_rng(rng, |digest: &mut C::Digest| {
            msg.iter().for_each(|slice| digest.update(slice));
            Ok(())
        })
    }
}

impl<C, D> DigestSigner<D, SignatureWithOid<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    D: AssociatedOid + Digest + FixedOutput,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign_digest<F: Fn(&mut D) -> Result<()>>(&self, f: F) -> Result<SignatureWithOid<C>> {
        let signature: Signature<C> = self.try_sign_digest(f)?;
        let oid = ecdsa_oid_for_digest(D::OID).ok_or_else(Error::new)?;
        SignatureWithOid::new(signature, oid)
    }
}

impl<C> Signer<SignatureWithOid<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    C::Digest: AssociatedOid,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_sign(&self, msg: &[u8]) -> Result<SignatureWithOid<C>> {
        self.try_multipart_sign(&[msg])
    }
}

impl<C> MultipartSigner<SignatureWithOid<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    C::Digest: AssociatedOid,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn try_multipart_sign(&self, msg: &[&[u8]]) -> Result<SignatureWithOid<C>> {
        self.try_sign_digest(|digest: &mut C::Digest| {
            msg.iter().for_each(|slice| digest.update(slice));
            Ok(())
        })
    }
}

#[cfg(feature = "der")]
impl<C> PrehashSigner<der::Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn sign_prehash(&self, prehash: &[u8]) -> Result<der::Signature<C>> {
        PrehashSigner::<Signature<C>>::sign_prehash(self, prehash).map(Into::into)
    }
}

#[cfg(feature = "der")]
impl<C> Signer<der::Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn try_sign(&self, msg: &[u8]) -> Result<der::Signature<C>> {
        Signer::<Signature<C>>::try_sign(self, msg).map(Into::into)
    }
}

#[cfg(feature = "der")]
impl<C, D> RandomizedDigestSigner<D, der::Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    D: Digest + FixedOutput,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn try_sign_digest_with_rng<R: TryCryptoRng + ?Sized, F: Fn(&mut D) -> Result<()>>(
        &self,
        rng: &mut R,
        f: F,
    ) -> Result<der::Signature<C>> {
        RandomizedDigestSigner::<D, Signature<C>>::try_sign_digest_with_rng(self, rng, f)
            .map(Into::into)
    }
}

#[cfg(feature = "der")]
impl<C> RandomizedPrehashSigner<der::Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn sign_prehash_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        prehash: &[u8],
    ) -> Result<der::Signature<C>> {
        RandomizedPrehashSigner::<Signature<C>>::sign_prehash_with_rng(self, rng, prehash)
            .map(Into::into)
    }
}

#[cfg(feature = "der")]
impl<D, C> DigestSigner<D, der::Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    D: Digest + FixedOutput,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn try_sign_digest<F: Fn(&mut D) -> Result<()>>(&self, f: F) -> Result<der::Signature<C>> {
        DigestSigner::<D, Signature<C>>::try_sign_digest(self, f).map(Into::into)
    }
}

#[cfg(feature = "der")]
impl<C> RandomizedSigner<der::Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn try_sign_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        msg: &[u8],
    ) -> Result<der::Signature<C>> {
        RandomizedSigner::<Signature<C>>::try_sign_with_rng(self, rng, msg).map(Into::into)
    }
}

#[cfg(feature = "der")]
impl<C> RandomizedMultipartSigner<der::Signature<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn try_multipart_sign_with_rng<R: TryCryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        msg: &[&[u8]],
    ) -> Result<der::Signature<C>> {
        RandomizedMultipartSigner::<Signature<C>>::try_multipart_sign_with_rng(self, rng, msg)
            .map(Into::into)
    }
}

//
// Other trait impls
//

#[cfg(feature = "verifying")]
impl<C> AsRef<VerifyingKey<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn as_ref(&self) -> &VerifyingKey<C> {
        &self.verifying_key
    }
}

impl<C> ConstantTimeEq for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn ct_eq(&self, other: &Self) -> Choice {
        self.secret_scalar.ct_eq(&other.secret_scalar)
    }
}

impl<C> Debug for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SigningKey").finish_non_exhaustive()
    }
}

impl<C> Drop for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn drop(&mut self) {
        self.secret_scalar.zeroize();
    }
}

/// Constant-time comparison
impl<C> Eq for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
}
impl<C> PartialEq for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn eq(&self, other: &SigningKey<C>) -> bool {
        self.ct_eq(other).into()
    }
}

impl<C> From<NonZeroScalar<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn from(secret_scalar: NonZeroScalar<C>) -> Self {
        #[cfg(feature = "verifying")]
        let public_key = PublicKey::from_secret_scalar(&secret_scalar);

        Self {
            secret_scalar,
            #[cfg(feature = "verifying")]
            verifying_key: public_key.into(),
        }
    }
}

impl<C> From<SecretKey<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn from(secret_key: SecretKey<C>) -> Self {
        Self::from(&secret_key)
    }
}

impl<C> From<&SecretKey<C>> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn from(secret_key: &SecretKey<C>) -> Self {
        secret_key.to_nonzero_scalar().into()
    }
}

impl<C> From<SigningKey<C>> for SecretKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn from(key: SigningKey<C>) -> Self {
        key.secret_scalar.into()
    }
}

impl<C> From<&SigningKey<C>> for SecretKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn from(secret_key: &SigningKey<C>) -> Self {
        secret_key.secret_scalar.into()
    }
}

impl<C> TryFrom<&[u8]> for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    type Error = Error;

    fn try_from(bytes: &[u8]) -> Result<Self> {
        Self::from_slice(bytes)
    }
}

impl<C> ZeroizeOnDrop for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
}

#[cfg(feature = "verifying")]
impl<C> From<SigningKey<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn from(signing_key: SigningKey<C>) -> VerifyingKey<C> {
        signing_key.verifying_key
    }
}

#[cfg(feature = "verifying")]
impl<C> From<&SigningKey<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn from(signing_key: &SigningKey<C>) -> VerifyingKey<C> {
        signing_key.verifying_key
    }
}

#[cfg(feature = "verifying")]
impl<C> KeypairRef for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    type VerifyingKey = VerifyingKey<C>;
}

#[cfg(feature = "pkcs8")]
impl<C> AssociatedAlgorithmIdentifier for SigningKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    type Params = ObjectIdentifier;

    const ALGORITHM_IDENTIFIER: AlgorithmIdentifier<ObjectIdentifier> =
        SecretKey::<C>::ALGORITHM_IDENTIFIER;
}

#[cfg(feature = "pkcs8")]
impl<C> SignatureAlgorithmIdentifier for SigningKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
    Signature<C>: AssociatedAlgorithmIdentifier<Params = AnyRef<'static>>,
{
    type Params = AnyRef<'static>;

    const SIGNATURE_ALGORITHM_IDENTIFIER: AlgorithmIdentifier<Self::Params> =
        Signature::<C>::ALGORITHM_IDENTIFIER;
}

#[cfg(feature = "pkcs8")]
impl<C> TryFrom<pkcs8::PrivateKeyInfoRef<'_>> for SigningKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    type Error = pkcs8::Error;

    fn try_from(private_key_info: pkcs8::PrivateKeyInfoRef<'_>) -> pkcs8::Result<Self> {
        SecretKey::try_from(private_key_info).map(Into::into)
    }
}

#[cfg(all(feature = "alloc", feature = "pkcs8"))]
impl<C> EncodePrivateKey for SigningKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    fn to_pkcs8_der(&self) -> pkcs8::Result<SecretDocument> {
        SecretKey::from(self.secret_scalar).to_pkcs8_der()
    }
}

#[cfg(feature = "pem")]
impl<C> FromStr for SigningKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
    Scalar<C>: Invert<Output = CtOption<Scalar<C>>>,
    SignatureSize<C>: ArraySize,
{
    type Err = Error;

    fn from_str(s: &str) -> Result<Self> {
        Self::from_pkcs8_pem(s).map_err(|_| Error::new())
    }
}
