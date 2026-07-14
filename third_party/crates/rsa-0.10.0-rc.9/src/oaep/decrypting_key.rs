use super::decrypt_digest;
use crate::{
    dummy_rng::DummyRng,
    traits::{Decryptor, RandomizedDecryptor},
    Result, RsaPrivateKey,
};
use alloc::{boxed::Box, vec::Vec};
use core::marker::PhantomData;
use digest::{Digest, FixedOutputReset};
use rand_core::CryptoRng;
#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};
use zeroize::ZeroizeOnDrop;

/// Decryption key for PKCS#1 v1.5 decryption as described in [RFC8017 § 7.1].
///
/// [RFC8017 § 7.1]: https://datatracker.ietf.org/doc/html/rfc8017#section-7.1
#[derive(Debug, Clone)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct DecryptingKey<D, MGD = D>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    inner: RsaPrivateKey,
    label: Option<Box<[u8]>>,
    phantom: PhantomData<D>,
    mg_phantom: PhantomData<MGD>,
}

impl<D, MGD> DecryptingKey<D, MGD>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    /// Create a new verifying key from an RSA public key.
    pub fn new(key: RsaPrivateKey) -> Self {
        Self {
            inner: key,
            label: None,
            phantom: Default::default(),
            mg_phantom: Default::default(),
        }
    }

    /// Create a new verifying key from an RSA public key using provided label
    pub fn new_with_label<S: Into<Box<[u8]>>>(key: RsaPrivateKey, label: S) -> Self {
        Self {
            inner: key,
            label: Some(label.into()),
            phantom: Default::default(),
            mg_phantom: Default::default(),
        }
    }
}

impl<D, MGD> Decryptor for DecryptingKey<D, MGD>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    fn decrypt(&self, ciphertext: &[u8]) -> Result<Vec<u8>> {
        decrypt_digest::<DummyRng, D, MGD>(None, &self.inner, ciphertext, self.label.clone())
    }
}

impl<D, MGD> RandomizedDecryptor for DecryptingKey<D, MGD>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
    fn decrypt_with_rng<R: CryptoRng + ?Sized>(
        &self,
        rng: &mut R,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>> {
        decrypt_digest::<_, D, MGD>(Some(rng), &self.inner, ciphertext, self.label.clone())
    }
}

impl<D, MGD> ZeroizeOnDrop for DecryptingKey<D, MGD>
where
    D: Digest,
    MGD: Digest + FixedOutputReset,
{
}

impl<D, MGD> PartialEq for DecryptingKey<D, MGD>
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
        use sha2::Sha256;

        let mut rng = ChaCha8Rng::from_seed([42; 32]);
        let decrypting_key = DecryptingKey::<Sha256>::new(
            RsaPrivateKey::new_unchecked(&mut rng, 64).expect("failed to generate key"),
        );

        let tokens = [
            Token::Struct {
                name: "DecryptingKey",
                len: 4,
            },
            Token::Str("inner"),
            Token::Str(concat!(
                "3056020100300d06092a864886f70d010101050004423040020100020900ab",
                "240c3361d02e370203010001020811e54a15259d22f9020500ceff5cf30205",
                "00d3a7aaad020500ccaddf17020500cb529d3d020500bb526d6f"
            )),
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
        assert_tokens(&decrypting_key.readable(), &tokens);
    }
}
