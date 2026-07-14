use super::encrypt_digest;
use crate::{traits::RandomizedEncryptor, Result, RsaPublicKey};
use alloc::{boxed::Box, vec::Vec};
use core::marker::PhantomData;
use digest::{Digest, FixedOutputReset};
use rand_core::CryptoRng;
#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};

/// Encryption key for PKCS#1 v1.5 encryption as described in [RFC8017 § 7.1].
///
/// [RFC8017 § 7.1]: https://datatracker.ietf.org/doc/html/rfc8017#section-7.1
#[derive(Debug, Clone)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct EncryptingKey<D, MGD = D>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    inner: RsaPublicKey,
    label: Option<Box<[u8]>>,
    phantom: PhantomData<D>,
    mg_phantom: PhantomData<MGD>,
}

impl<D, MGD> EncryptingKey<D, MGD>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    /// Create a new verifying key from an RSA public key.
    pub fn new(key: RsaPublicKey) -> Self {
        Self {
            inner: key,
            label: None,
            phantom: Default::default(),
            mg_phantom: Default::default(),
        }
    }

    /// Create a new verifying key from an RSA public key using provided label
    pub fn new_with_label<S: Into<Box<[u8]>>>(key: RsaPublicKey, label: S) -> Self {
        Self {
            inner: key,
            label: Some(label.into()),
            phantom: Default::default(),
            mg_phantom: Default::default(),
        }
    }
}

impl<D, MGD> RandomizedEncryptor for EncryptingKey<D, MGD>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    fn encrypt_with_rng<R: CryptoRng + ?Sized>(&self, rng: &mut R, msg: &[u8]) -> Result<Vec<u8>> {
        encrypt_digest::<_, D, MGD>(rng, &self.inner, msg, self.label.clone())
    }
}

impl<D, MGD> PartialEq for EncryptingKey<D, MGD>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    fn eq(&self, other: &Self) -> bool {
        self.inner == other.inner && self.label == other.label
    }
}

#[cfg(test)]
mod tests {

    #[test]
    #[cfg(all(feature = "hazmat", feature = "serde"))]
    fn test_serde() {
        use super::*;
        use rand_chacha::{rand_core::SeedableRng, ChaCha8Rng};
        use serde_test::{assert_tokens, Configure, Token};

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let priv_key =
            crate::RsaPrivateKey::new_unchecked(&mut rng, 64).expect("failed to generate key");
        let encrypting_key = EncryptingKey::<sha2::Sha256>::new(priv_key.to_public_key());

        let tokens = [
            Token::Struct {
                name: "EncryptingKey",
                len: 4,
            },
            Token::Str("inner"),
            Token::Str(
                "3024300d06092a864886f70d01010105000313003010020900ab240c3361d02e370203010001",
            ),
            Token::Str("label"),
            Token::None,
            Token::Str("phantom"),
            Token::UnitStruct {
                name: "PhantomData",
            },
            Token::Str("mg_phantom"),
            Token::UnitStruct {
                name: "PhantomData",
            },
            Token::StructEnd,
        ];
        assert_tokens(&encrypting_key.readable(), &tokens);
    }
}
