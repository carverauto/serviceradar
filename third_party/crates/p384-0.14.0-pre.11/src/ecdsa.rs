//! Elliptic Curve Digital Signature Algorithm (ECDSA)
//!
//! This module contains support for computing and verifying ECDSA signatures.
//! To use it, you will need to enable one of the two following Cargo features:
//!
//! - `ecdsa-core`: provides only the [`Signature`] type (which represents an
//!   ECDSA/P-384 signature). Does not require the `arithmetic` feature. This is
//!   useful for 3rd-party crates which wish to use the `Signature` type for
//!   interoperability purposes (particularly in conjunction with the
//!   [`signature::Signer`] trait. Example use cases for this include other
//!   software implementations of ECDSA/P-384 and wrappers for cloud KMS
//!   services or hardware devices (HSM or crypto hardware wallet).
//! - `ecdsa`: provides `ecdsa-core` features plus the [`SigningKey`] and
//!   [`VerifyingKey`] types which natively implement ECDSA/P-384 signing and
//!   verification.
//!
//! ## Signing/Verification Example
//!
//! This example requires the `ecdsa` Cargo feature is enabled:
//!
//! ```
//! # #[cfg(feature = "ecdsa")]
//! # {
//! use p384::ecdsa::{signature::Signer, Signature, SigningKey};
//! use rand_core::{OsRng, TryRngCore}; // requires 'os_rng' feature
//!
//! // Signing
//! let signing_key = SigningKey::try_from_rng(&mut OsRng).unwrap(); // Serialize with `::to_bytes()`
//! let message = b"ECDSA proves knowledge of a secret number in the context of a single message";
//! let signature: Signature = signing_key.sign(message);
//!
//! // Verification
//! use p384::ecdsa::{signature::Verifier, VerifyingKey};
//!
//! let verifying_key = VerifyingKey::from(&signing_key); // Serialize with `::to_encoded_point()`
//! assert!(verifying_key.verify(message, &signature).is_ok());
//! # }
//! ```

pub use ecdsa_core::signature::{self, Error};

use super::NistP384;
use ecdsa_core::EcdsaCurve;

/// ECDSA/P-384 signature (fixed-size)
pub type Signature = ecdsa_core::Signature<NistP384>;

/// ECDSA/P-384 signature (ASN.1 DER encoded)
pub type DerSignature = ecdsa_core::der::Signature<NistP384>;

impl EcdsaCurve for NistP384 {
    const NORMALIZE_S: bool = false;
}

/// ECDSA/P-384 signing key
#[cfg(feature = "ecdsa")]
pub type SigningKey = ecdsa_core::SigningKey<NistP384>;

/// ECDSA/P-384 verification key (i.e. public key)
#[cfg(feature = "ecdsa")]
pub type VerifyingKey = ecdsa_core::VerifyingKey<NistP384>;

#[cfg(feature = "sha384")]
impl ecdsa_core::hazmat::DigestAlgorithm for NistP384 {
    type Digest = sha2::Sha384;
}

#[cfg(all(test, feature = "ecdsa"))]
mod tests {
    use crate::{
        AffinePoint, EncodedPoint, SecretKey,
        ecdsa::{
            Signature, SigningKey, VerifyingKey,
            signature::Signer,
            signature::hazmat::{PrehashSigner, PrehashVerifier},
        },
    };

    use elliptic_curve::sec1::FromEncodedPoint;
    use hex_literal::hex;
    use sha2::Digest;

    // Test vector from RFC 6979 Appendix 2.6 (NIST P-384 + SHA-384)
    // <https://tools.ietf.org/html/rfc6979#appendix-A.2.6>
    #[test]
    fn rfc6979() {
        let x = hex!(
            "6b9d3dad2e1b8c1c05b19875b6659f4de23c3b667bf297ba9aa47740787137d896d5724e4c70a825f872c9ea60d2edf5"
        );
        let signer = SigningKey::from_bytes(&x.into()).unwrap();
        let signature: Signature = signer.sign(b"sample");
        assert_eq!(
            signature.to_bytes().as_slice(),
            &hex!(
                "94edbb92a5ecb8aad4736e56c691916b3f88140666ce9fa73d64c4ea95ad133c81a648152e44acf96e36dd1e80fabe46
                99ef4aeb15f178cea1fe40db2603138f130e740a19624526203b6351d0a3a94fa329c145786e679e7b82c71a38628ac8"
            )
        );

        let signature: Signature = signer.sign(b"test");
        assert_eq!(
            signature.to_bytes().as_slice(),
            &hex!(
                "8203b63d3c853e8d77227fb377bcf7b7b772e97892a80f36ab775d509d7a5feb0542a7f0812998da8f1dd3ca3cf023db
                ddd0760448d42d8a43af45af836fce4de8be06b485e9b61b827c2f13173923e06a739f040649a667bf3b828246baa5a5"
            )
        );
    }

    // Test signing with PrehashSigner using SHA-256 whose output is smaller than P-384 field size.
    #[test]
    fn prehash_signer_signing_with_sha256() {
        let x = hex!(
            "6b9d3dad2e1b8c1c05b19875b6659f4de23c3b667bf297ba9aa47740787137d896d5724e4c70a825f872c9ea60d2edf5"
        );
        let signer = SigningKey::from_bytes(&x.into()).unwrap();
        let digest = sha2::Sha256::digest(b"test");
        let signature: Signature = signer.sign_prehash(&digest).unwrap();
        assert_eq!(
            signature.to_bytes().as_slice(),
            &hex!(
                "010c3ab1a300f8c9d63eafa9a41813f0c5416c08814bdfc0236458d6c2603d71c4941f4696e60aff5717476170bb6ab4
                03c4ad6274c61691346b2178def879424726909af308596ffb6355a042f48a114e2eb28eaa6918592b4727961057c0c1"
            )
        );
    }

    // Test verifying with PrehashVerifier using SHA-256 whose output is smaller than P-384 field size.
    #[test]
    fn prehash_signer_verification_with_sha256() {
        // The following test vector adapted from the FIPS 186-4 ECDSA test vectors
        // (P-384, SHA-256, from `SigGen.txt` in `186-4ecdsatestvectors.zip`)
        // <https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program/digital-signatures>
        let verifier = VerifyingKey::from_affine(
            AffinePoint::from_encoded_point(
                &EncodedPoint::from_affine_coordinates(
                    &hex!("0400193b21f07cd059826e9453d3e96dd145041c97d49ff6b7047f86bb0b0439e909274cb9c282bfab88674c0765bc75").into(),
                    &hex! ("f70d89c52acbc70468d2c5ae75c76d7f69b76af62dcf95e99eba5dd11adf8f42ec9a425b0c5ec98e2f234a926b82a147").into(),
                    false,
                ),
            ).unwrap()
        ).unwrap();
        let signature = Signature::from_scalars(
            hex!("b11db00cdaf53286d4483f38cd02785948477ed7ebc2ad609054551da0ab0359978c61851788aa2ec3267946d440e878"),
            hex!("16007873c5b0604ce68112a8fee973e8e2b6e3319c683a762ff5065a076512d7c98b27e74b7887671048ac027df8cbf2"),
        ).unwrap();
        let result = verifier.verify_prehash(
            &hex!("bbbd0a5f645d3fda10e288d172b299455f9dff00e0fbc2833e18cd017d7f3ed1"),
            &signature,
        );
        assert!(result.is_ok());
    }

    #[test]
    fn signing_secret_key_equivalent() {
        let raw_sk: [u8; 48] = [
            32, 52, 118, 9, 96, 116, 119, 172, 168, 251, 251, 197, 230, 33, 132, 85, 243, 25, 150,
            105, 121, 46, 248, 180, 102, 250, 168, 123, 220, 103, 121, 129, 68, 200, 72, 221, 3,
            102, 30, 237, 90, 198, 36, 97, 52, 12, 234, 150,
        ];

        let seck = SecretKey::from_bytes(&raw_sk.into()).unwrap();
        let sigk = SigningKey::from_bytes(&raw_sk.into()).unwrap();

        assert_eq!(seck.to_bytes().as_slice(), &raw_sk);
        assert_eq!(sigk.to_bytes().as_slice(), &raw_sk);
    }

    mod sign {
        use crate::{NistP384, test_vectors::ecdsa::ECDSA_TEST_VECTORS};
        ecdsa_core::new_signing_test!(NistP384, ECDSA_TEST_VECTORS);
    }

    mod verify {
        use crate::{NistP384, test_vectors::ecdsa::ECDSA_TEST_VECTORS};
        ecdsa_core::new_verification_test!(NistP384, ECDSA_TEST_VECTORS);
    }

    mod wycheproof {
        use crate::NistP384;
        ecdsa_core::new_wycheproof_test!(wycheproof, "wycheproof", NistP384);
    }
}
