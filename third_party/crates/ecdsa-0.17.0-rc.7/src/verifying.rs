//! ECDSA verifying: checking signatures are authentic using a [`VerifyingKey`].

use crate::{
    EcdsaCurve, Error, Result, Signature, SignatureSize,
    hazmat::{self, DigestAlgorithm, bits2field},
};
use core::{cmp::Ordering, fmt::Debug};
use elliptic_curve::{
    AffinePoint, CurveArithmetic, FieldBytesSize, ProjectivePoint, PublicKey,
    array::ArraySize,
    point::PointCompression,
    scalar::IsHigh,
    sec1::{self, CompressedPoint, EncodedPoint, FromEncodedPoint, ToEncodedPoint},
};
use signature::{
    DigestVerifier, MultipartVerifier, Verifier,
    digest::{Digest, FixedOutput},
    hazmat::PrehashVerifier,
};

#[cfg(feature = "alloc")]
use alloc::boxed::Box;

#[cfg(feature = "der")]
use {crate::der, core::ops::Add};

#[cfg(feature = "pem")]
use {core::str::FromStr, elliptic_curve::pkcs8::DecodePublicKey};

#[cfg(feature = "pkcs8")]
use elliptic_curve::pkcs8::{
    self, AssociatedOid, ObjectIdentifier,
    der::AnyRef,
    spki::{
        self, AlgorithmIdentifier, AssociatedAlgorithmIdentifier, SignatureAlgorithmIdentifier,
    },
};

#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Serialize, de, ser};

#[cfg(feature = "sha2")]
use {
    crate::{
        ECDSA_SHA224_OID, ECDSA_SHA256_OID, ECDSA_SHA384_OID, ECDSA_SHA512_OID, SignatureWithOid,
    },
    sha2::{Sha224, Sha256, Sha384, Sha512},
};

#[cfg(all(feature = "alloc", feature = "pkcs8"))]
use elliptic_curve::pkcs8::EncodePublicKey;

/// ECDSA public key used for verifying signatures. Generic over prime order
/// elliptic curves (e.g. NIST P-curves).
///
/// Requires an [`elliptic_curve::CurveArithmetic`] impl on the curve.
///
/// ## Usage
///
/// The [`signature`] crate defines the following traits which are the
/// primary API for verifying:
///
/// - [`Verifier`]: verify a message against a provided key and signature
/// - [`DigestVerifier`]: verify a message [`Digest`] against a provided key and signature
/// - [`PrehashVerifier`]: verify the low-level raw output bytes of a message digest
///
/// See the [`p256` crate](https://docs.rs/p256/latest/p256/ecdsa/index.html)
/// for examples of using this type with a concrete elliptic curve.
///
/// # `serde` support
///
/// When the `serde` feature of this crate is enabled, it provides support for
/// serializing and deserializing ECDSA signatures using the `Serialize` and
/// `Deserialize` traits.
///
/// The serialization leverages the encoding used by the [`PublicKey`] type,
/// which is a binary-oriented ASN.1 DER encoding.
#[derive(Clone, Debug)]
pub struct VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
{
    pub(crate) inner: PublicKey<C>,
}

impl<C> VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    /// Initialize [`VerifyingKey`] from a SEC1-encoded public key.
    pub fn from_sec1_bytes(bytes: &[u8]) -> Result<Self> {
        PublicKey::from_sec1_bytes(bytes)
            .map(|pk| Self { inner: pk })
            .map_err(|_| Error::new())
    }

    /// Initialize [`VerifyingKey`] from an affine point.
    ///
    /// Returns an [`Error`] if the given affine point is the additive identity
    /// (a.k.a. point at infinity).
    pub fn from_affine(affine: AffinePoint<C>) -> Result<Self> {
        Ok(Self {
            inner: PublicKey::from_affine(affine).map_err(|_| Error::new())?,
        })
    }

    /// Initialize [`VerifyingKey`] from an [`EncodedPoint`].
    pub fn from_encoded_point(public_key: &EncodedPoint<C>) -> Result<Self> {
        PublicKey::<C>::from_encoded_point(public_key)
            .into_option()
            .map(|public_key| Self { inner: public_key })
            .ok_or_else(Error::new)
    }

    /// Serialize this [`VerifyingKey`] as a SEC1 [`EncodedPoint`], optionally
    /// applying point compression.
    pub fn to_encoded_point(&self, compress: bool) -> EncodedPoint<C> {
        self.inner.to_encoded_point(compress)
    }

    /// Convert this [`VerifyingKey`] into the
    /// `Elliptic-Curve-Point-to-Octet-String` encoding described in
    /// SEC 1: Elliptic Curve Cryptography (Version 2.0) section 2.3.3
    /// (page 10).
    ///
    /// <http://www.secg.org/sec1-v2.pdf>
    #[cfg(feature = "alloc")]
    pub fn to_sec1_bytes(&self) -> Box<[u8]>
    where
        C: PointCompression,
    {
        self.inner.to_sec1_bytes()
    }

    /// Borrow the inner [`AffinePoint`] for this public key.
    pub fn as_affine(&self) -> &AffinePoint<C> {
        self.inner.as_affine()
    }
}

//
// `*Verifier` trait impls
//

impl<C, D> DigestVerifier<D, Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    D: Digest + FixedOutput,
    SignatureSize<C>: ArraySize,
{
    fn verify_digest<F: Fn(&mut D) -> Result<()>>(
        &self,
        f: F,
        signature: &Signature<C>,
    ) -> Result<()> {
        let mut digest = D::new();
        f(&mut digest)?;
        self.verify_prehash(&digest.finalize(), signature)
    }
}

impl<C> PrehashVerifier<Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    SignatureSize<C>: ArraySize,
{
    fn verify_prehash(&self, prehash: &[u8], signature: &Signature<C>) -> Result<()> {
        if C::NORMALIZE_S && signature.s().is_high().into() {
            return Err(Error::new());
        }

        hazmat::verify_prehashed::<C>(
            &ProjectivePoint::<C>::from(*self.inner.as_affine()),
            &bits2field::<C>(prehash)?,
            signature,
        )
    }
}

impl<C> Verifier<Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    SignatureSize<C>: ArraySize,
{
    fn verify(&self, msg: &[u8], signature: &Signature<C>) -> Result<()> {
        self.multipart_verify(&[msg], signature)
    }
}

impl<C> MultipartVerifier<Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    SignatureSize<C>: ArraySize,
{
    fn multipart_verify(&self, msg: &[&[u8]], signature: &Signature<C>) -> Result<()> {
        self.verify_digest(
            |digest: &mut C::Digest| {
                msg.iter().for_each(|slice| digest.update(slice));
                Ok(())
            },
            signature,
        )
    }
}

#[cfg(feature = "sha2")]
impl<C> Verifier<SignatureWithOid<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    SignatureSize<C>: ArraySize,
{
    fn verify(&self, msg: &[u8], sig: &SignatureWithOid<C>) -> Result<()> {
        self.multipart_verify(&[msg], sig)
    }
}

#[cfg(feature = "sha2")]
impl<C> MultipartVerifier<SignatureWithOid<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    SignatureSize<C>: ArraySize,
{
    fn multipart_verify(&self, msg: &[&[u8]], sig: &SignatureWithOid<C>) -> Result<()> {
        match sig.oid() {
            ECDSA_SHA224_OID => {
                let mut digest = Sha224::new();
                msg.iter().for_each(|slice| digest.update(slice));
                self.verify_prehash(&digest.finalize(), sig.signature())
            }
            ECDSA_SHA256_OID => {
                let mut digest = Sha256::new();
                msg.iter().for_each(|slice| digest.update(slice));
                self.verify_prehash(&digest.finalize(), sig.signature())
            }
            ECDSA_SHA384_OID => {
                let mut digest = Sha384::new();
                msg.iter().for_each(|slice| digest.update(slice));
                self.verify_prehash(&digest.finalize(), sig.signature())
            }
            ECDSA_SHA512_OID => {
                let mut digest = Sha512::new();
                msg.iter().for_each(|slice| digest.update(slice));
                self.verify_prehash(&digest.finalize(), sig.signature())
            }
            _ => Err(Error::new()),
        }
    }
}

#[cfg(feature = "der")]
impl<C, D> DigestVerifier<D, der::Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    D: Digest + FixedOutput,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn verify_digest<F: Fn(&mut D) -> Result<()>>(
        &self,
        f: F,
        signature: &der::Signature<C>,
    ) -> Result<()> {
        let signature = Signature::<C>::try_from(signature.clone())?;
        DigestVerifier::<D, Signature<C>>::verify_digest(self, f, &signature)
    }
}

#[cfg(feature = "der")]
impl<C> PrehashVerifier<der::Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn verify_prehash(&self, prehash: &[u8], signature: &der::Signature<C>) -> Result<()> {
        let signature = Signature::<C>::try_from(signature.clone())?;
        PrehashVerifier::<Signature<C>>::verify_prehash(self, prehash, &signature)
    }
}

#[cfg(feature = "der")]
impl<C> Verifier<der::Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn verify(&self, msg: &[u8], signature: &der::Signature<C>) -> Result<()> {
        let signature = Signature::<C>::try_from(signature.clone())?;
        Verifier::<Signature<C>>::verify(self, msg, &signature)
    }
}

#[cfg(feature = "der")]
impl<C> MultipartVerifier<der::Signature<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic + DigestAlgorithm,
    SignatureSize<C>: ArraySize,
    der::MaxSize<C>: ArraySize,
    <FieldBytesSize<C> as Add>::Output: Add<der::MaxOverhead> + ArraySize,
{
    fn multipart_verify(&self, msg: &[&[u8]], signature: &der::Signature<C>) -> Result<()> {
        let signature = Signature::<C>::try_from(signature.clone())?;
        MultipartVerifier::<Signature<C>>::multipart_verify(self, msg, &signature)
    }
}

//
// Other trait impls
//

impl<C> AsRef<AffinePoint<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn as_ref(&self) -> &AffinePoint<C> {
        self.as_affine()
    }
}

impl<C> Copy for VerifyingKey<C> where C: EcdsaCurve + CurveArithmetic {}

impl<C> From<VerifyingKey<C>> for CompressedPoint<C>
where
    C: EcdsaCurve + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn from(verifying_key: VerifyingKey<C>) -> CompressedPoint<C> {
        verifying_key.inner.into()
    }
}

impl<C> From<&VerifyingKey<C>> for CompressedPoint<C>
where
    C: EcdsaCurve + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn from(verifying_key: &VerifyingKey<C>) -> CompressedPoint<C> {
        verifying_key.inner.into()
    }
}

impl<C> From<VerifyingKey<C>> for EncodedPoint<C>
where
    C: EcdsaCurve + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn from(verifying_key: VerifyingKey<C>) -> EncodedPoint<C> {
        verifying_key.inner.into()
    }
}

impl<C> From<&VerifyingKey<C>> for EncodedPoint<C>
where
    C: EcdsaCurve + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn from(verifying_key: &VerifyingKey<C>) -> EncodedPoint<C> {
        verifying_key.inner.into()
    }
}

impl<C> Eq for VerifyingKey<C> where C: EcdsaCurve + CurveArithmetic {}

impl<C> PartialEq for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
{
    fn eq(&self, other: &Self) -> bool {
        self.inner.eq(&other.inner)
    }
}

impl<C> From<PublicKey<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
{
    fn from(public_key: PublicKey<C>) -> VerifyingKey<C> {
        VerifyingKey { inner: public_key }
    }
}

impl<C> From<&PublicKey<C>> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
{
    fn from(public_key: &PublicKey<C>) -> VerifyingKey<C> {
        (*public_key).into()
    }
}

impl<C> From<VerifyingKey<C>> for PublicKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
{
    fn from(verifying_key: VerifyingKey<C>) -> PublicKey<C> {
        verifying_key.inner
    }
}

impl<C> From<&VerifyingKey<C>> for PublicKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
{
    fn from(verifying_key: &VerifyingKey<C>) -> PublicKey<C> {
        (*verifying_key).into()
    }
}

impl<C> PartialOrd for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<C> Ord for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn cmp(&self, other: &Self) -> Ordering {
        self.inner.cmp(&other.inner)
    }
}

impl<C> TryFrom<&[u8]> for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    type Error = Error;

    fn try_from(bytes: &[u8]) -> Result<Self> {
        Self::from_sec1_bytes(bytes)
    }
}

#[cfg(feature = "pkcs8")]
impl<C> AssociatedAlgorithmIdentifier for VerifyingKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    type Params = ObjectIdentifier;

    const ALGORITHM_IDENTIFIER: AlgorithmIdentifier<ObjectIdentifier> =
        PublicKey::<C>::ALGORITHM_IDENTIFIER;
}

#[cfg(feature = "pkcs8")]
impl<C> SignatureAlgorithmIdentifier for VerifyingKey<C>
where
    C: EcdsaCurve + CurveArithmetic,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
    Signature<C>: AssociatedAlgorithmIdentifier<Params = AnyRef<'static>>,
{
    type Params = AnyRef<'static>;

    const SIGNATURE_ALGORITHM_IDENTIFIER: AlgorithmIdentifier<Self::Params> =
        Signature::<C>::ALGORITHM_IDENTIFIER;
}

#[cfg(feature = "pkcs8")]
impl<C> TryFrom<pkcs8::SubjectPublicKeyInfoRef<'_>> for VerifyingKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    type Error = spki::Error;

    fn try_from(spki: pkcs8::SubjectPublicKeyInfoRef<'_>) -> spki::Result<Self> {
        PublicKey::try_from(spki).map(|inner| Self { inner })
    }
}

#[cfg(all(feature = "alloc", feature = "pkcs8"))]
impl<C> EncodePublicKey for VerifyingKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn to_public_key_der(&self) -> spki::Result<pkcs8::Document> {
        self.inner.to_public_key_der()
    }
}

#[cfg(feature = "pem")]
impl<C> FromStr for VerifyingKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    type Err = Error;

    fn from_str(s: &str) -> Result<Self> {
        Self::from_public_key_pem(s).map_err(|_| Error::new())
    }
}

#[cfg(feature = "serde")]
impl<C> Serialize for VerifyingKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn serialize<S>(&self, serializer: S) -> core::result::Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        self.inner.serialize(serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de, C> Deserialize<'de> for VerifyingKey<C>
where
    C: EcdsaCurve + AssociatedOid + CurveArithmetic + PointCompression,
    AffinePoint<C>: FromEncodedPoint<C> + ToEncodedPoint<C>,
    FieldBytesSize<C>: sec1::ModulusSize,
{
    fn deserialize<D>(deserializer: D) -> core::result::Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        PublicKey::<C>::deserialize(deserializer).map(Into::into)
    }
}
