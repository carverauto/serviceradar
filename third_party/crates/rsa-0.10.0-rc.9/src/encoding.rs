//! PKCS#1 and PKCS#8 encoding support.
//!
//! Note: PKCS#1 support is achieved through a blanket impl of the
//! `pkcs1` crate's traits for types which impl the `pkcs8` crate's traits.

#![cfg(feature = "encoding")]

use crate::{
    traits::{PrivateKeyParts, PublicKeyParts},
    RsaPrivateKey, RsaPublicKey,
};
use core::convert::{TryFrom, TryInto};
use crypto_bigint::{BoxedUint, NonZero, Resize};
use pkcs8::{
    der::{asn1::OctetStringRef, Decode},
    Document, EncodePrivateKey, EncodePublicKey, ObjectIdentifier, SecretDocument,
};
use zeroize::Zeroizing;

/// ObjectID for the RSA PSS keys
pub const ID_RSASSA_PSS: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.1.10");

// PKCS#1

fn uint_from_slice(data: &[u8], bits: u32) -> pkcs1::Result<BoxedUint> {
    BoxedUint::from_be_slice(data, bits).map_err(|_| pkcs1::Error::KeyMalformed)
}

impl pkcs1::DecodeRsaPrivateKey for RsaPrivateKey {
    fn from_pkcs1_der(bytes: &[u8]) -> pkcs1::Result<Self> {
        pkcs1::RsaPrivateKey::from_der(bytes)?.try_into()
    }
}

impl pkcs1::DecodeRsaPublicKey for RsaPublicKey {
    fn from_pkcs1_der(bytes: &[u8]) -> pkcs1::Result<Self> {
        pkcs1::RsaPublicKey::from_der(bytes)?.try_into()
    }
}

impl TryFrom<pkcs1::RsaPrivateKey<'_>> for RsaPrivateKey {
    type Error = pkcs1::Error;

    fn try_from(pkcs1_key: pkcs1::RsaPrivateKey<'_>) -> pkcs1::Result<RsaPrivateKey> {
        use pkcs1::Error::KeyMalformed;

        // Multi-prime RSA keys not currently supported
        if pkcs1_key.version() != pkcs1::Version::TwoPrime {
            return Err(pkcs1::Error::Version);
        }

        let bits = u32::try_from(pkcs1_key.modulus.as_bytes().len()).map_err(|_| KeyMalformed)? * 8;

        let n = uint_from_slice(pkcs1_key.modulus.as_bytes(), bits)?;
        let bits_e = u32::try_from(pkcs1_key.public_exponent.as_bytes().len())
            .map_err(|_| pkcs1::Error::KeyMalformed)?
            * 8;
        let e = uint_from_slice(pkcs1_key.public_exponent.as_bytes(), bits_e)?;
        let e = Option::from(e).ok_or(KeyMalformed)?;

        let d = uint_from_slice(pkcs1_key.private_exponent.as_bytes(), bits)?;
        let prime1 = uint_from_slice(pkcs1_key.prime1.as_bytes(), bits)?;
        let prime2 = uint_from_slice(pkcs1_key.prime2.as_bytes(), bits)?;
        let primes = vec![prime1, prime2];

        RsaPrivateKey::from_components(n, e, d, primes).map_err(|_| KeyMalformed)
    }
}

impl TryFrom<pkcs1::RsaPublicKey<'_>> for RsaPublicKey {
    type Error = pkcs1::Error;

    fn try_from(pkcs1_key: pkcs1::RsaPublicKey<'_>) -> pkcs1::Result<Self> {
        use pkcs1::Error::KeyMalformed;

        let bits = u32::try_from(pkcs1_key.modulus.as_bytes().len()).map_err(|_| KeyMalformed)? * 8;
        let n = uint_from_slice(pkcs1_key.modulus.as_bytes(), bits)?;

        let bits_e = u32::try_from(pkcs1_key.public_exponent.as_bytes().len())
            .map_err(|_| KeyMalformed)?
            * 8;
        let e = uint_from_slice(pkcs1_key.public_exponent.as_bytes(), bits_e)?;

        RsaPublicKey::new(n, e).map_err(|_| KeyMalformed)
    }
}

impl pkcs1::EncodeRsaPrivateKey for RsaPrivateKey {
    fn to_pkcs1_der(&self) -> pkcs1::Result<SecretDocument> {
        // Check if the key is multi prime
        if self.primes.len() > 2 {
            return Err(pkcs1::Error::Crypto);
        }

        let modulus = self.n().to_be_bytes();
        let public_exponent = self.e().to_be_bytes();
        let private_exponent = Zeroizing::new(self.d().to_be_bytes());
        let prime1 = Zeroizing::new(self.primes[0].to_be_bytes());
        let prime2 = Zeroizing::new(self.primes[1].to_be_bytes());

        let bits = self.d().bits_precision();

        debug_assert!(bits >= self.primes[0].bits_vartime());
        debug_assert!(bits >= self.primes[1].bits_vartime());

        let exponent1 = Zeroizing::new(
            (self.d()
                % NonZero::new((&self.primes[0]).resize_unchecked(bits) - &BoxedUint::one())
                    .unwrap())
            .to_be_bytes(),
        );
        let exponent2 = Zeroizing::new(
            (self.d()
                % NonZero::new((&self.primes[1]).resize_unchecked(bits) - &BoxedUint::one())
                    .unwrap())
            .to_be_bytes(),
        );
        let coefficient = Zeroizing::new(
            self.crt_coefficient()
                .ok_or(pkcs1::Error::Crypto)?
                .to_be_bytes(),
        );

        Ok(SecretDocument::encode_msg(&pkcs1::RsaPrivateKey {
            modulus: pkcs1::UintRef::new(&modulus)?,
            public_exponent: pkcs1::UintRef::new(&public_exponent)?,
            private_exponent: pkcs1::UintRef::new(&private_exponent)?,
            prime1: pkcs1::UintRef::new(&prime1)?,
            prime2: pkcs1::UintRef::new(&prime2)?,
            exponent1: pkcs1::UintRef::new(&exponent1)?,
            exponent2: pkcs1::UintRef::new(&exponent2)?,
            coefficient: pkcs1::UintRef::new(&coefficient)?,
            other_prime_infos: None,
        })?)
    }
}

impl pkcs1::EncodeRsaPublicKey for RsaPublicKey {
    fn to_pkcs1_der(&self) -> pkcs1::Result<Document> {
        let modulus = self.n().to_be_bytes();
        let public_exponent = self.e().to_be_bytes();

        Ok(Document::encode_msg(&pkcs1::RsaPublicKey {
            modulus: pkcs1::UintRef::new(&modulus)?,
            public_exponent: pkcs1::UintRef::new(&public_exponent)?,
        })?)
    }
}

// PKCS#8

/// Verify that the `AlgorithmIdentifier` for a key is correct.
pub(crate) fn verify_algorithm_id(algorithm: &spki::AlgorithmIdentifierRef) -> spki::Result<()> {
    match algorithm.oid {
        pkcs1::ALGORITHM_OID => {
            if algorithm.parameters_any()? != pkcs8::der::asn1::Null.into() {
                return Err(spki::Error::KeyMalformed);
            }
        }
        ID_RSASSA_PSS => {
            if algorithm.parameters.is_some() {
                return Err(spki::Error::KeyMalformed);
            }
        }
        _ => return Err(spki::Error::OidUnknown { oid: algorithm.oid }),
    };

    Ok(())
}

impl TryFrom<pkcs8::PrivateKeyInfoRef<'_>> for RsaPrivateKey {
    type Error = pkcs8::Error;

    fn try_from(private_key_info: pkcs8::PrivateKeyInfoRef<'_>) -> pkcs8::Result<Self> {
        verify_algorithm_id(&private_key_info.algorithm)?;

        pkcs1::RsaPrivateKey::try_from(private_key_info.private_key)
            .and_then(TryInto::try_into)
            .map_err(pkcs1_error_to_pkcs8)
    }
}

impl TryFrom<pkcs8::SubjectPublicKeyInfoRef<'_>> for RsaPublicKey {
    type Error = spki::Error;

    fn try_from(spki: pkcs8::SubjectPublicKeyInfoRef<'_>) -> spki::Result<Self> {
        use spki::Error::KeyMalformed;

        verify_algorithm_id(&spki.algorithm)?;

        pkcs1::RsaPublicKey::try_from(spki.subject_public_key.as_bytes().ok_or(KeyMalformed)?)
            .and_then(TryInto::try_into)
            .map_err(pkcs1_error_to_spki)
    }
}

impl EncodePrivateKey for RsaPrivateKey {
    fn to_pkcs8_der(&self) -> pkcs8::Result<SecretDocument> {
        let private_key =
            pkcs1::EncodeRsaPrivateKey::to_pkcs1_der(self).map_err(pkcs1_error_to_pkcs8)?;

        pkcs8::PrivateKeyInfoRef::new(
            pkcs1::ALGORITHM_ID,
            OctetStringRef::new(private_key.as_bytes())?,
        )
        .try_into()
    }
}

impl EncodePublicKey for RsaPublicKey {
    fn to_public_key_der(&self) -> spki::Result<Document> {
        let subject_public_key =
            pkcs1::EncodeRsaPublicKey::to_pkcs1_der(self).map_err(pkcs1_error_to_spki)?;

        pkcs8::SubjectPublicKeyInfoRef {
            algorithm: pkcs1::ALGORITHM_ID,
            subject_public_key: pkcs8::der::asn1::BitStringRef::new(
                0,
                subject_public_key.as_ref(),
            )?,
        }
        .try_into()
    }
}

/// Convert `pkcs1::Result` to `pkcs8::Result`.
fn pkcs1_error_to_pkcs8(error: pkcs1::Error) -> pkcs8::Error {
    match error {
        pkcs1::Error::Asn1(e) => pkcs8::Error::Asn1(e),
        _ => pkcs8::Error::KeyMalformed,
    }
}

/// Convert `pkcs1::Result` to `spki::Result`.
fn pkcs1_error_to_spki(error: pkcs1::Error) -> spki::Error {
    match error {
        pkcs1::Error::Asn1(e) => spki::Error::Asn1(e),
        _ => spki::Error::KeyMalformed,
    }
}
