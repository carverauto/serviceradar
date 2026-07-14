use crate::{
    decode_raw, decode_seed, encode, encode_prefix, encode_seed, err, KeyPairType,
    PREFIX_BYTE_CURVE, PREFIX_BYTE_PRIVATE,
};

use super::Result;
use crypto_box::{
    aead::{Aead, AeadCore},
    Nonce, SalsaBox,
};
use ed25519::signature::digest::typenum::Unsigned;
use std::fmt::{self, Debug};

const XKEY_VERSION_V1: &[u8] = b"xkv1";

use crypto_box::{PublicKey, SecretKey};
use rand::{CryptoRng, Rng, RngCore};

/// The main interface used for reading and writing _nkey-encoded_ curve key
/// pairs.
#[derive(Clone)]
pub struct XKey {
    public: PublicKey,
    secret: Option<SecretKey>,
}

impl Debug for XKey {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "XKey")
    }
}

impl XKey {
    /// Creates a new xkey.
    ///
    /// NOTE: This is not available if using on a wasm32-unknown-unknown target due to the lack of
    /// rand support. Use [`new_from_raw`](XKey::new_from_raw) instead
    #[cfg(not(target_arch = "wasm32"))]
    pub fn new() -> Self {
        Self::new_with_rand(&mut rand::rngs::OsRng)
    }

    /// Create a new xkey pair from a random generator
    ///
    /// NOTE: These generator should be a cryptographically secure random source.
    ///
    /// NOTE: This is not available if using on a wasm32-unknown-unknown target due to the lack of
    /// rand support. Use [`new_from_raw`](XKey::new_from_raw) instead
    #[cfg(not(target_arch = "wasm32"))]
    pub fn new_with_rand(rand: &mut (impl CryptoRng + RngCore)) -> Self {
        Self::new_from_raw(rand.gen())
    }

    /// Create a new xkey pair using a pre-existing set of random bytes.
    ///
    /// NOTE: These bytes should be generated from a cryptographically secure random source.
    pub fn new_from_raw(random_bytes: [u8; 32]) -> Self {
        let private = SecretKey::from_bytes(random_bytes);
        Self {
            public: private.public_key(),
            secret: Some(private),
        }
    }

    /// Attempts to produce a public-only xkey from the given encoded public key string
    pub fn from_public_key(source: &str) -> Result<Self> {
        let source_bytes = source.as_bytes();
        let raw = decode_raw(source_bytes)?;

        let (prefix, rest) = raw.split_first().ok_or(err!(VerifyError, "Empty key"))?;
        if *prefix != PREFIX_BYTE_CURVE {
            Err(err!(
                InvalidPrefix,
                "Not a valid public key prefix: {}",
                raw[0]
            ))
        } else {
            let public = PublicKey::try_from(rest)
                .map_err(|_| err!(VerifyError, "Could not read public key"))?;

            Ok(Self {
                public,
                secret: None,
            })
        }
    }

    /// Attempts to produce a full xkey pair from the given encoded seed string
    pub fn from_seed(source: &str) -> Result<Self> {
        let (ty, seed) = decode_seed(source)?;

        if ty != PREFIX_BYTE_CURVE {
            return Err(err!(
                InvalidPrefix,
                "Expected a curve, got {:?}",
                KeyPairType::from(ty)
            ));
        }

        let secret = SecretKey::from_bytes(seed);
        Ok(Self {
            public: secret.public_key(),
            secret: Some(secret),
        })
    }

    /// Attempts to return the encoded, human-readable string for this key pair's seed.
    /// Remember that this value should be treated as a secret. Do not store it for
    /// any longer than necessary
    pub fn seed(&self) -> Result<String> {
        let Some(secret) = &self.secret else {
            return Err(err!(IncorrectKeyType, "This keypair has no seed"));
        };

        Ok(encode_seed(&KeyPairType::Curve, &secret.to_bytes()))
    }

    /// Returns the encoded, human-readable public key of this key pair
    pub fn public_key(&self) -> String {
        encode(&KeyPairType::Curve, self.public.as_bytes())
    }

    pub fn private_key(&self) -> Result<String> {
        let Some(secret) = &self.secret else {
            return Err(err!(IncorrectKeyType, "This keypair has no seed"));
        };

        Ok(encode_prefix(&[PREFIX_BYTE_PRIVATE], &secret.to_bytes()))
    }

    /// Returns the type of this key pair.
    pub fn key_pair_type(&self) -> KeyPairType {
        KeyPairType::Curve
    }

    pub fn open(&self, input: &[u8], sender: &Self) -> Result<Vec<u8>> {
        let nonce_size = <SalsaBox as AeadCore>::NonceSize::to_usize();

        let Some(secret_key) = &self.secret else {
            return Err(err!(SignatureError, "Cannot open without a private key"));
        };

        if input.len() <= XKEY_VERSION_V1.len() + nonce_size {
            return Err(err!(InvalidPayload, "Payload too short"));
        }

        let Some(input) = input.strip_prefix(XKEY_VERSION_V1) else {
            return Err(err!(InvalidPrefix, "Cannot open message, wrong version"));
        };

        let (nonce, input) = input.split_at(nonce_size);

        let b = SalsaBox::new(&sender.public, secret_key);
        b.decrypt(nonce.into(), input)
            .map_err(|_| err!(InvalidPayload, "Cannot decrypt payload"))
    }

    /// Seal is compatible with nacl.Box.Seal() and can be used in similar situations for small
    /// messages. We generate the nonce from crypto rand by default.
    ///
    /// NOTE: This is not available if using on a wasm32-unknown-unknown target due to the lack of
    /// rand support. Use [`seal_with_nonce`](XKey::seal_with_nonce) instead
    #[cfg(not(target_arch = "wasm32"))]
    pub fn seal(&self, input: &[u8], recipient: &Self) -> Result<Vec<u8>> {
        self.seal_with_rand(input, recipient, &mut rand::rngs::OsRng)
    }

    /// NOTE: This is not available if using on a wasm32-unknown-unknown target due to the lack of
    /// rand support. Use [`seal_with_nonce`](XKey::seal_with_nonce) instead
    #[cfg(not(target_arch = "wasm32"))]
    pub fn seal_with_rand(
        &self,
        input: &[u8],
        recipient: &Self,
        rand: impl CryptoRng + RngCore,
    ) -> Result<Vec<u8>> {
        let nonce = SalsaBox::generate_nonce(rand);
        self.seal_with_nonce(input, recipient, nonce)
    }

    /// NOTE: Nonce bytes should be generated from a cryptographically secure random source, and
    /// only be used once.
    pub fn seal_with_nonce(&self, input: &[u8], recipient: &Self, nonce: Nonce) -> Result<Vec<u8>> {
        let Some(private_key) = &self.secret else {
            return Err(err!(SignatureError, "Cannot seal without a private key"));
        };

        let b = SalsaBox::new(&recipient.public, private_key);
        let crypted = b
            .encrypt(&nonce, input)
            .map_err(|_| err!(SignatureError, "Cannot seal payload"))?; // Can't fail when used with SalsaBox

        let mut out = Vec::with_capacity(
            XKEY_VERSION_V1.len()
                + <SalsaBox as AeadCore>::NonceSize::to_usize()
                + input.len()
                + <SalsaBox as AeadCore>::TagSize::to_usize(),
        );
        out.extend_from_slice(XKEY_VERSION_V1);
        out.extend_from_slice(nonce.as_slice());
        out.extend_from_slice(&crypted);

        Ok(out)
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl Default for XKey {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorKind;
    const MESSAGE: &[u8] = b"this is super secret";

    #[test]
    fn seed_encode_decode_round_trip() {
        let pair = XKey::new();
        let s = pair.seed().unwrap();
        let p = pair.public_key();

        let pair2 = XKey::from_seed(s.as_str()).unwrap();
        let s2 = pair2.seed().unwrap();

        assert_eq!(s, s2);
        assert_eq!(p, pair2.public_key());
    }

    #[test]
    fn roundtrip_encoding_go_compat() {
        // Seed and Public Key pair generated by Go nkeys library
        let seed = "SXAKIYZX2POLIHZ5W5YZEWVTH24NLEUETBW3TKIVYRSS3GNHFXO5D4JJZM";
        let pk = "XBUJMZHVOPQ2SK5VD3TY4VNBPVU2YFGRLK6EFPEPSMVDUYEBSROWZCEA";

        let pair = XKey::from_seed(seed).unwrap();

        assert_eq!(pair.seed().unwrap(), seed);
        assert_eq!(pair.public_key(), pk);
    }

    #[test]
    fn from_seed_rejects_bad_prefix() {
        let seed = "SZAIB67JMUPS5OKP6BZNCFTIMHOTS6JIX2C53TLSNEROIRFBJLSK3NUOVY";
        let pair = XKey::from_seed(seed);
        assert!(pair.is_err());
        if let Err(e) = pair {
            assert_eq!(e.kind(), ErrorKind::InvalidPrefix);
        }
    }

    #[test]
    fn from_seed_rejects_bad_length() {
        let seed = "SXAKIYZX2POLIHZ5W5YZEWVTH24NLEUETBW3TKIVYRSS3GNHFXO5D4JJZMA";
        let pair = XKey::from_seed(seed);
        assert!(pair.is_err());
        if let Err(e) = pair {
            assert_eq!(e.kind(), ErrorKind::InvalidKeyLength);
        }
    }

    #[test]
    fn from_seed_rejects_invalid_encoding() {
        let badseed = "SXAKIYZX2POLIHZ5W5YZEWVTH24NLEUETBW3TKIVYRSS!GNHFXO5D4JJZM";
        let pair = XKey::from_seed(badseed);
        assert!(pair.is_err());
        if let Err(e) = pair {
            assert_eq!(e.kind(), ErrorKind::CodecFailure);
        }
    }

    #[test]
    fn public_key_round_trip() {
        let src_pk = "XBUJMZHVOPQ2SK5VD3TY4VNBPVU2YFGRLK6EFPEPSMVDUYEBSROWZCEA";
        let account = XKey::from_public_key(src_pk).unwrap();
        let pk = account.public_key();
        assert_eq!(pk, src_pk);
    }

    #[test]
    fn has_proper_prefix() {
        let module = XKey::new();
        assert!(module.seed().unwrap().starts_with("SX"));
        assert!(module.public_key().starts_with('X'));
    }

    #[test]
    fn xkeys_convert_to_public() {
        let sender_pub =
            XKey::from_public_key("XBUJMZHVOPQ2SK5VD3TY4VNBPVU2YFGRLK6EFPEPSMVDUYEBSROWZCEA")
                .unwrap();
        let sender =
            XKey::from_seed("SXAKIYZX2POLIHZ5W5YZEWVTH24NLEUETBW3TKIVYRSS3GNHFXO5D4JJZM").unwrap();

        assert_eq!(sender.public_key(), sender_pub.public_key());
    }

    #[test]
    fn seal_and_open() {
        let sender = XKey::new();
        let receiver = XKey::new();

        let boxed = sender.seal(MESSAGE, &receiver).unwrap();

        let res = receiver.open(&boxed, &sender).unwrap();
        assert_eq!(MESSAGE, res.as_slice());
    }

    #[test]
    fn tamper_version() {
        let sender = XKey::new();
        let receiver = XKey::new();

        let mut boxed = sender.seal(MESSAGE, &receiver).unwrap();

        // Tamper with message
        boxed[0] += 1;

        let err = receiver.open(&boxed, &sender).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidPrefix);
    }

    #[test]
    fn tamper_message() {
        let sender = XKey::new();
        let receiver = XKey::new();

        let mut boxed = sender.seal(MESSAGE, &receiver).unwrap();

        // Tamper with message
        boxed[XKEY_VERSION_V1.len() + 1] += 1;

        let err = receiver.open(&boxed, &sender).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidPayload);
    }

    #[test]
    fn wrong_key() {
        let sender = XKey::new();
        let receiver = XKey::new();
        let random_key = XKey::new();

        let boxed = sender.seal(MESSAGE, &receiver).unwrap();

        let err = random_key.open(&boxed, &sender).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidPayload);
    }

    #[test]
    fn open_from_go() {
        let receiver =
            XKey::from_seed("SXAHGC56LJFTSRXFC653AT7XZU6WGYIXU4XFPMCT62GGHFLUCSPVYP764M").unwrap();
        let sender =
            XKey::from_public_key("XBUJMZHVOPQ2SK5VD3TY4VNBPVU2YFGRLK6EFPEPSMVDUYEBSROWZCEA")
                .unwrap();
        let raw_sender =
            XKey::from_seed("SXAKIYZX2POLIHZ5W5YZEWVTH24NLEUETBW3TKIVYRSS3GNHFXO5D4JJZM").unwrap();
        assert_eq!(sender.public_key(), raw_sender.public_key());

        // Message generated with nkeys Go library
        let boxed = [
            0x78, 0x6b, 0x76, 0x31, 0x46, 0x76, 0x98, 0xf9, 0x87, 0x3, 0x50, 0x2f, 0x42, 0x41,
            0xb7, 0xa7, 0x34, 0x72, 0x98, 0x0, 0x92, 0x9f, 0x6d, 0x9, 0x4b, 0x6, 0xc6, 0xe3, 0x4a,
            0x78, 0xde, 0x49, 0x9e, 0xe7, 0xde, 0xbb, 0xac, 0x94, 0x77, 0x55, 0x6f, 0x3f, 0xbb,
            0xe9, 0xf, 0xfd, 0x67, 0x8b, 0xc6, 0x29, 0xe5, 0xb7, 0xcc, 0x7c, 0x57, 0x40, 0x4d,
            0x92, 0x38, 0x46, 0xcf, 0x1, 0x2, 0x26,
        ];

        let out = receiver.open(&boxed, &raw_sender).unwrap();
        assert_eq!(std::str::from_utf8(&out), Ok("this is super secret"));
    }
}
