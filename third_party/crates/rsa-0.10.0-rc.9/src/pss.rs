//! Support for the [Probabilistic Signature Scheme] (PSS) a.k.a. RSASSA-PSS.
//!
//! Designed by Mihir Bellare and Phillip Rogaway. Specified in [RFC8017 § 8.1].
//!
//! # Usage
//!
//! See [code example in the toplevel rustdoc](../index.html#pss-signatures).
//!
//! [Probabilistic Signature Scheme]: https://en.wikipedia.org/wiki/Probabilistic_signature_scheme
//! [RFC8017 § 8.1]: https://datatracker.ietf.org/doc/html/rfc8017#section-8.1

mod blinded_signing_key;
mod signature;
mod signing_key;
mod verifying_key;

pub use self::{
    blinded_signing_key::BlindedSigningKey, signature::Signature, signing_key::SigningKey,
    verifying_key::VerifyingKey,
};

use alloc::{boxed::Box, vec::Vec};
use core::fmt::{self, Debug};
use crypto_bigint::BoxedUint;

use digest::{Digest, DynDigest, FixedOutputReset};
use rand_core::TryCryptoRng;

use crate::algorithms::pad::{uint_to_be_pad, uint_to_zeroizing_be_pad};
use crate::algorithms::pss::*;
use crate::algorithms::rsa::{rsa_decrypt_and_check, rsa_encrypt};
use crate::errors::{Error, Result};
use crate::traits::PublicKeyParts;
use crate::traits::SignatureScheme;
use crate::{RsaPrivateKey, RsaPublicKey};

#[cfg(feature = "encoding")]
use {
    crate::encoding::ID_RSASSA_PSS,
    const_oid::AssociatedOid,
    pkcs1::RsaPssParams,
    spki::{der::Any, AlgorithmIdentifierOwned},
};

/// Digital signatures using PSS padding.
pub struct Pss {
    /// Create blinded signatures.
    pub blinded: bool,

    /// Digest type to use.
    pub digest: Box<dyn DynDigest + Send + Sync>,

    /// Salt length.
    /// Required for signing, optional for verifying.
    pub salt_len: Option<usize>,
}

impl Pss {
    /// New PSS padding for the given digest.
    /// Digest output size is used as a salt length.
    pub fn new<T: 'static + Digest + DynDigest + Send + Sync>() -> Self {
        Self::new_with_salt::<T>(<T as Digest>::output_size())
    }

    /// New PSS padding for the given digest with a salt value of the given length.
    pub fn new_with_salt<T: 'static + Digest + DynDigest + Send + Sync>(len: usize) -> Self {
        Self {
            blinded: false,
            digest: Box::new(T::new()),
            salt_len: Some(len),
        }
    }

    /// New PSS padding for blinded signatures (RSA-BSSA) for the given digest.
    /// Digest output size is used as a salt length.
    pub fn new_blinded<T: 'static + Digest + DynDigest + Send + Sync>() -> Self {
        Self::new_blinded_with_salt::<T>(<T as Digest>::output_size())
    }

    /// New PSS padding for blinded signatures (RSA-BSSA) for the given digest
    /// with a salt value of the given length.
    pub fn new_blinded_with_salt<T: 'static + Digest + DynDigest + Send + Sync>(
        len: usize,
    ) -> Self {
        Self {
            blinded: true,
            digest: Box::new(T::new()),
            salt_len: Some(len),
        }
    }
}

impl SignatureScheme for Pss {
    fn sign<Rng: TryCryptoRng + ?Sized>(
        mut self,
        rng: Option<&mut Rng>,
        priv_key: &RsaPrivateKey,
        hashed: &[u8],
    ) -> Result<Vec<u8>> {
        sign(
            rng.ok_or(Error::InvalidPaddingScheme)?,
            self.blinded,
            priv_key,
            hashed,
            self.salt_len.expect("salt_len to be Some"),
            &mut *self.digest,
        )
    }

    fn verify(mut self, pub_key: &RsaPublicKey, hashed: &[u8], sig: &[u8]) -> Result<()> {
        verify(
            pub_key,
            hashed,
            &BoxedUint::from_be_slice_vartime(sig),
            sig.len(),
            &mut *self.digest,
            self.salt_len,
        )
    }
}

impl Debug for Pss {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PSS")
            .field("blinded", &self.blinded)
            .field("digest", &"...")
            .field("salt_len", &self.salt_len)
            .finish()
    }
}

pub(crate) fn verify(
    pub_key: &RsaPublicKey,
    hashed: &[u8],
    sig: &BoxedUint,
    sig_len: usize,
    digest: &mut dyn DynDigest,
    salt_len: Option<usize>,
) -> Result<()> {
    if sig_len != pub_key.size() {
        return Err(Error::Verification);
    }
    let raw = rsa_encrypt(pub_key, sig)?;
    let mut em = uint_to_be_pad(raw, pub_key.size())?;

    emsa_pss_verify(hashed, &mut em, salt_len, digest, pub_key.n().bits() as _)
}

pub(crate) fn verify_digest<D>(
    pub_key: &RsaPublicKey,
    hashed: &[u8],
    sig: &BoxedUint,
    salt_len: Option<usize>,
) -> Result<()>
where
    D: Digest + FixedOutputReset,
{
    let n = pub_key.n();
    if sig >= n.as_ref() || sig.bits_precision() != pub_key.n_bits_precision() {
        return Err(Error::Verification);
    }

    let mut em = uint_to_be_pad(rsa_encrypt(pub_key, sig)?, pub_key.size())?;

    emsa_pss_verify_digest::<D>(hashed, &mut em, salt_len, pub_key.n().bits() as _)
}

/// SignPSS calculates the signature of hashed using RSASSA-PSS.
///
/// Note that hashed must be the result of hashing the input message using the
/// given hash function. The opts argument may be nil, in which case sensible
/// defaults are used.
pub(crate) fn sign<T: TryCryptoRng + ?Sized>(
    rng: &mut T,
    blind: bool,
    priv_key: &RsaPrivateKey,
    hashed: &[u8],
    salt_len: usize,
    digest: &mut dyn DynDigest,
) -> Result<Vec<u8>> {
    let mut salt = vec![0; salt_len];
    rng.try_fill_bytes(&mut salt[..]).map_err(|_| Error::Rng)?;

    sign_pss_with_salt(blind.then_some(rng), priv_key, hashed, &salt, digest)
}

pub(crate) fn sign_digest<T: TryCryptoRng + ?Sized, D: Digest + FixedOutputReset>(
    rng: &mut T,
    blind: bool,
    priv_key: &RsaPrivateKey,
    hashed: &[u8],
    salt_len: usize,
) -> Result<Vec<u8>> {
    let mut salt = vec![0; salt_len];
    rng.try_fill_bytes(&mut salt[..]).map_err(|_| Error::Rng)?;

    sign_pss_with_salt_digest::<_, D>(blind.then_some(rng), priv_key, hashed, &salt)
}

/// signPSSWithSalt calculates the signature of hashed using PSS with specified salt.
///
/// Note that hashed must be the result of hashing the input message using the
/// given hash function. salt is a random sequence of bytes whose length will be
/// later used to verify the signature.
fn sign_pss_with_salt<T: TryCryptoRng + ?Sized>(
    blind_rng: Option<&mut T>,
    priv_key: &RsaPrivateKey,
    hashed: &[u8],
    salt: &[u8],
    digest: &mut dyn DynDigest,
) -> Result<Vec<u8>> {
    let em_bits = priv_key.n().bits() - 1;

    let em = emsa_pss_encode(hashed, em_bits as _, salt, digest)?;

    let em = BoxedUint::from_be_slice(&em, priv_key.n_bits_precision())?;
    let raw = rsa_decrypt_and_check(priv_key, blind_rng, &em)?;
    uint_to_zeroizing_be_pad(raw, priv_key.size())
}

fn sign_pss_with_salt_digest<T: TryCryptoRng + ?Sized, D: Digest + FixedOutputReset>(
    blind_rng: Option<&mut T>,
    priv_key: &RsaPrivateKey,
    hashed: &[u8],
    salt: &[u8],
) -> Result<Vec<u8>> {
    let em_bits = priv_key.n().bits() - 1;
    let em = emsa_pss_encode_digest::<D>(hashed, em_bits as _, salt)?;

    let em = BoxedUint::from_be_slice(&em, priv_key.n_bits_precision())?;
    uint_to_zeroizing_be_pad(
        rsa_decrypt_and_check(priv_key, blind_rng, &em)?,
        priv_key.size(),
    )
}

/// Returns the [`AlgorithmIdentifierOwned`] associated with PSS signature using a given digest.
#[cfg(feature = "encoding")]
pub fn get_default_pss_signature_algo_id<D>() -> spki::Result<AlgorithmIdentifierOwned>
where
    D: Digest + AssociatedOid,
{
    let salt_len: u8 = <D as Digest>::output_size() as u8;
    get_pss_signature_algo_id::<D>(salt_len)
}

#[cfg(feature = "encoding")]
fn get_pss_signature_algo_id<D>(salt_len: u8) -> spki::Result<AlgorithmIdentifierOwned>
where
    D: Digest + AssociatedOid,
{
    let pss_params = RsaPssParams::new::<D>(salt_len);

    Ok(AlgorithmIdentifierOwned {
        oid: ID_RSASSA_PSS,
        parameters: Some(Any::encode_from(&pss_params)?),
    })
}

#[cfg(all(test, feature = "encoding"))]
mod test {
    use crate::pss::{BlindedSigningKey, Pss, Signature, SigningKey, VerifyingKey};
    use crate::{RsaPrivateKey, RsaPublicKey};

    use crate::traits::PublicKeyParts;
    use hex_literal::hex;
    use pkcs1::DecodeRsaPrivateKey;
    use rand_chacha::{rand_core::SeedableRng, ChaCha8Rng};
    use rstest::rstest;
    use sha1::{Digest, Sha1};
    use signature::hazmat::{PrehashVerifier, RandomizedPrehashSigner};
    use signature::{DigestVerifier, Keypair, RandomizedDigestSigner, RandomizedSigner, Verifier};

    fn get_private_key() -> RsaPrivateKey {
        // In order to generate new test vectors you'll need the PEM form of this key:
        // -----BEGIN RSA PRIVATE KEY-----
        // MIIBOgIBAAJBALKZD0nEffqM1ACuak0bijtqE2QrI/KLADv7l3kK3ppMyCuLKoF0
        // fd7Ai2KW5ToIwzFofvJcS/STa6HA5gQenRUCAwEAAQJBAIq9amn00aS0h/CrjXqu
        // /ThglAXJmZhOMPVn4eiu7/ROixi9sex436MaVeMqSNf7Ex9a8fRNfWss7Sqd9eWu
        // RTUCIQDasvGASLqmjeffBNLTXV2A5g4t+kLVCpsEIZAycV5GswIhANEPLmax0ME/
        // EO+ZJ79TJKN5yiGBRsv5yvx5UiHxajEXAiAhAol5N4EUyq6I9w1rYdhPMGpLfk7A
        // IU2snfRJ6Nq2CQIgFrPsWRCkV+gOYcajD17rEqmuLrdIRexpg8N1DOSXoJ8CIGlS
        // tAboUGBxTDq3ZroNism3DaMIbKPyYrAqhKov1h5V
        // -----END RSA PRIVATE KEY-----

        let pem = r#"
-----BEGIN RSA PRIVATE KEY-----
MIIBOgIBAAJBALKZD0nEffqM1ACuak0bijtqE2QrI/KLADv7l3kK3ppMyCuLKoF0
fd7Ai2KW5ToIwzFofvJcS/STa6HA5gQenRUCAwEAAQJBAIq9amn00aS0h/CrjXqu
/ThglAXJmZhOMPVn4eiu7/ROixi9sex436MaVeMqSNf7Ex9a8fRNfWss7Sqd9eWu
RTUCIQDasvGASLqmjeffBNLTXV2A5g4t+kLVCpsEIZAycV5GswIhANEPLmax0ME/
EO+ZJ79TJKN5yiGBRsv5yvx5UiHxajEXAiAhAol5N4EUyq6I9w1rYdhPMGpLfk7A
IU2snfRJ6Nq2CQIgFrPsWRCkV+gOYcajD17rEqmuLrdIRexpg8N1DOSXoJ8CIGlS
tAboUGBxTDq3ZroNism3DaMIbKPyYrAqhKov1h5V
-----END RSA PRIVATE KEY-----"#;

        RsaPrivateKey::from_pkcs1_pem(pem).unwrap()
    }

    #[rstest]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962f"
        ),
        true,
    )]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962e"
        ),
        false,
    )]
    fn test_verify_pss(#[case] text: &str, #[case] sig: [u8; 64], #[case] expected: bool) {
        let priv_key = get_private_key();
        let pub_key: RsaPublicKey = priv_key.into();

        let digest = Sha1::digest(text.as_bytes()).to_vec();
        let result = pub_key.verify(Pss::new::<Sha1>(), &digest, &sig);

        match expected {
            true => result.expect("failed to verify"),
            false => {
                result.expect_err("expected verifying error");
            }
        }
    }

    #[rstest]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962f"
        ),
        true,
    )]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962e"
        ),
        false,
    )]
    fn test_verify_pss_signer(#[case] text: &str, #[case] sig: [u8; 64], #[case] expected: bool) {
        let priv_key = get_private_key();
        let pub_key: RsaPublicKey = priv_key.into();
        let verifying_key: VerifyingKey<Sha1> = VerifyingKey::new(pub_key);

        let result = verifying_key.verify(
            text.as_bytes(),
            &Signature::try_from(sig.as_slice()).unwrap(),
        );
        match expected {
            true => result.expect("failed to verify"),
            false => {
                result.expect_err("expected verifying error");
            }
        }
    }

    #[rstest]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962f"
        ),
        true,
    )]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962e"
        ),
        false,
    )]
    fn test_verify_pss_digest_signer(
        #[case] text: &str,
        #[case] sig: [u8; 64],
        #[case] expected: bool,
    ) {
        let priv_key = get_private_key();
        let pub_key: RsaPublicKey = priv_key.into();
        let verifying_key = VerifyingKey::new(pub_key);

        let result = verifying_key.verify_digest(
            |digest: &mut Sha1| {
                digest.update(text.as_bytes());
                Ok(())
            },
            &Signature::try_from(sig.as_slice()).unwrap(),
        );
        match expected {
            true => result.expect("failed to verify"),
            false => {
                result.expect_err("expected verifying error");
            }
        }
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_roundtrip(#[case] test: &str) {
        let priv_key = get_private_key();

        let rng = ChaCha8Rng::from_seed([42; 32]);

        let digest = Sha1::digest(test.as_bytes()).to_vec();
        let sig = priv_key
            .sign_with_rng(&mut rng.clone(), Pss::new::<Sha1>(), &digest)
            .expect("failed to sign");

        priv_key
            .to_public_key()
            .verify(Pss::new::<Sha1>(), &digest, &sig)
            .expect("failed to verify");
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_blinded_and_verify_roundtrip(#[case] test: &str) {
        let priv_key = get_private_key();

        let rng = ChaCha8Rng::from_seed([42; 32]);

        let digest = Sha1::digest(test.as_bytes()).to_vec();
        let sig = priv_key
            .sign_with_rng(&mut rng.clone(), Pss::new_blinded::<Sha1>(), &digest)
            .expect("failed to sign");

        priv_key
            .to_public_key()
            .verify(Pss::new::<Sha1>(), &digest, &sig)
            .expect("failed to verify");
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_roundtrip_signer(#[case] test: &str) {
        let priv_key = get_private_key();

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let signing_key = SigningKey::<Sha1>::new(priv_key);
        let verifying_key = signing_key.verifying_key();

        let sig = signing_key.sign_with_rng(&mut rng, test.as_bytes());
        verifying_key
            .verify(test.as_bytes(), &sig)
            .expect("failed to verify");
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_roundtrip_blinded_signer(#[case] test: &str) {
        let priv_key = get_private_key();

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let signing_key = BlindedSigningKey::<Sha1>::new(priv_key);
        let verifying_key = signing_key.verifying_key();

        let sig = signing_key.sign_with_rng(&mut rng, test.as_bytes());
        verifying_key
            .verify(test.as_bytes(), &sig)
            .expect("failed to verify");
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_roundtrip_digest_signer(#[case] test: &str) {
        let priv_key = get_private_key();

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let signing_key = SigningKey::new(priv_key);
        let verifying_key = signing_key.verifying_key();

        let sig = signing_key
            .sign_digest_with_rng(&mut rng, |digest: &mut Sha1| digest.update(test.as_bytes()));

        verifying_key
            .verify_digest(
                |digest: &mut Sha1| {
                    digest.update(test.as_bytes());
                    Ok(())
                },
                &sig,
            )
            .expect("failed to verify");
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_roundtrip_blinded_digest_signer(#[case] test: &str) {
        let priv_key = get_private_key();

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let signing_key = BlindedSigningKey::<Sha1>::new(priv_key);
        let verifying_key = signing_key.verifying_key();

        let sig = signing_key
            .sign_digest_with_rng(&mut rng, |digest: &mut Sha1| digest.update(test.as_bytes()));

        verifying_key
            .verify_digest(
                |digest: &mut Sha1| {
                    digest.update(test.as_bytes());
                    Ok(())
                },
                &sig,
            )
            .expect("failed to verify");
    }

    #[rstest]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962f"
        ),
        true
    )]
    #[case(
        "test\n",
        hex!(
            "6f86f26b14372b2279f79fb6807c49889835c204f71e38249b4c5601462da8ae"
            "30f26ffdd9c13f1c75eee172bebe7b7c89f2f1526c722833b9737d6c172a962e"
        ),
        false
    )]
    fn test_verify_pss_hazmat(#[case] text: &str, #[case] sig: [u8; 64], #[case] expected: bool) {
        let text = Sha1::digest(text);
        let priv_key = get_private_key();

        let pub_key: RsaPublicKey = priv_key.into();
        let verifying_key = VerifyingKey::<Sha1>::new(pub_key);

        let result = verifying_key
            .verify_prehash(text.as_ref(), &Signature::try_from(sig.as_slice()).unwrap());
        match expected {
            true => result.expect("failed to verify"),
            false => {
                result.expect_err("expected verifying error");
            }
        }
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_pss_hazmat(#[case] test: &str) {
        let test = &Sha1::digest(test);
        let priv_key = get_private_key();

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let signing_key = SigningKey::<Sha1>::new(priv_key);
        let verifying_key = signing_key.verifying_key();

        let sig = signing_key
            .sign_prehash_with_rng(&mut rng, test)
            .expect("failed to sign");
        verifying_key
            .verify_prehash(test, &sig)
            .expect("failed to verify");
    }

    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_pss_blinded_hazmat(#[case] test: &str) {
        let priv_key = get_private_key();

        let test = &Sha1::digest(test);
        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let signing_key = BlindedSigningKey::<Sha1>::new(priv_key);
        let verifying_key = signing_key.verifying_key();

        let sig = signing_key
            .sign_prehash_with_rng(&mut rng, test)
            .expect("failed to sign");
        verifying_key
            .verify_prehash(test, &sig)
            .expect("failed to verify");
    }

    #[test]
    // Tests the corner case where the key is multiple of 8 + 1 bits long
    fn test_sign_and_verify_2049bit_key() {
        let plaintext = "Hello\n";
        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        for i in 0..10 {
            println!("round {i}");
            let priv_key = RsaPrivateKey::new(&mut rng, 2049).unwrap();

            let digest = Sha1::digest(plaintext.as_bytes()).to_vec();
            let sig = priv_key
                .sign_with_rng(&mut rng, Pss::new::<Sha1>(), &digest)
                .expect("failed to sign");

            priv_key
                .to_public_key()
                .verify(Pss::new::<Sha1>(), &digest, &sig)
                .expect("failed to verify");
        }
    }

    // Tests the case where the salt length used for signing differs from the default length
    // while the verifier uses auto-detection.
    #[rstest]
    #[case("test\n")]
    fn test_sign_and_verify_pss_differing_salt_len(#[case] test: &str) {
        let priv_key = get_private_key();

        let mut rng = ChaCha8Rng::from_seed([42; 32]);

        // signing keys using different salt lengths
        let signing_keys = [
            // default salt length
            SigningKey::<Sha1>::new(priv_key.clone()),
            // maximum salt length
            SigningKey::<Sha1>::new_with_salt_len(
                priv_key.clone(),
                priv_key.size() - Sha1::output_size() - 2,
            ),
            // unsalted
            SigningKey::<Sha1>::new_with_salt_len(priv_key.clone(), 0),
        ];

        // verifying key uses default salt length strategy
        let verifying_key = VerifyingKey::<Sha1>::new_with_auto_salt_len(priv_key.to_public_key());

        for signing_key in &signing_keys {
            let sig = signing_key.sign_with_rng(&mut rng, test.as_bytes());
            verifying_key
                .verify(test.as_bytes(), &sig)
                .expect("verification to succeed");
        }
    }
}
