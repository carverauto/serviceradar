//! Elliptic Curve Digital Signature Algorithm (ECDSA)
//!
//! This module contains support for computing and verifying ECDSA signatures.
//! To use it, you will need to enable one of the two following Cargo features:
//!
//! - `ecdsa-core`: provides only the [`Signature`] type (which represents an
//!   ECDSA/P-521 signature). Does not require the `arithmetic` feature. This is
//!   useful for 3rd-party crates which wish to use the `Signature` type for
//!   interoperability purposes (particularly in conjunction with the
//!   [`signature::Signer`] trait. Example use cases for this include other
//!   software implementations of ECDSA/P-521 and wrappers for cloud KMS
//!   services or hardware devices (HSM or crypto hardware wallet).
//! - `ecdsa`: provides `ecdsa-core` features plus the [`SigningKey`] and
//!   [`VerifyingKey`] types which natively implement ECDSA/P-521 signing and
//!   verification.
//!
//! ## Signing/Verification Example
//!
//! This example requires the `ecdsa` Cargo feature is enabled:
//!
//! ```
//! # #[cfg(feature = "ecdsa")]
//! # {
//! use p521::ecdsa::{signature::Signer, Signature, SigningKey};
//! use rand_core::OsRng; // requires 'os_rng' feature
//!
//! // Signing
//! let signing_key = SigningKey::try_from_rng(&mut OsRng).unwrap(); // Serialize with `::to_bytes()`
//! let message = b"ECDSA proves knowledge of a secret number in the context of a single message";
//! let signature: Signature = signing_key.sign(message);
//!
//! // Verification
//! use p521::ecdsa::{signature::Verifier, VerifyingKey};
//!
//! let verifying_key = VerifyingKey::from(&signing_key); // Serialize with `::to_encoded_point()`
//! assert!(verifying_key.verify(message, &signature).is_ok());
//! # }
//! ```

pub use ecdsa_core::signature::{self, Error};

use super::NistP521;
use ecdsa_core::EcdsaCurve;

/// ECDSA/P-521 signature (fixed-size)
pub type Signature = ecdsa_core::Signature<NistP521>;

/// ECDSA/P-521 signature (ASN.1 DER encoded)
pub type DerSignature = ecdsa_core::der::Signature<NistP521>;

impl EcdsaCurve for NistP521 {
    const NORMALIZE_S: bool = false;
}

/// ECDSA/P-521 signing key
#[cfg(feature = "ecdsa")]
pub type SigningKey = ecdsa_core::SigningKey<NistP521>;

/// ECDSA/P-521 verification key (i.e. public key)
#[cfg(feature = "ecdsa")]
pub type VerifyingKey = ecdsa_core::VerifyingKey<NistP521>;

#[cfg(feature = "sha512")]
impl ecdsa_core::hazmat::DigestAlgorithm for NistP521 {
    type Digest = sha2::Sha512;
}

#[cfg(all(test, feature = "ecdsa"))]
mod tests {
    use crate::ecdsa::{Signature, SigningKey, signature::Signer};
    use hex_literal::hex;

    // Test vector from RFC 6979 Appendix 2.7 (NIST P-521 + SHA-512)
    // <https://datatracker.ietf.org/doc/html/rfc6979#appendix-A.2.7>
    // TODO(tarcieri): debug why this is failing
    #[test]
    fn rfc6979() {
        let x = hex!(
            "00FAD06DAA62BA3B25D2FB40133DA757205DE67F5BB0018FEE8C86E1B68C7E75CAA896EB32F1F47C70855836A6D16FCC1466F6D8FBEC67DB89EC0C08B0E996B83538"
        );
        let signer = SigningKey::from_bytes(&x.into()).unwrap();
        let signature: Signature = signer.sign(b"sample");
        assert_eq!(
            signature.to_bytes().as_slice(),
            &hex!(
                "00C328FAFCBD79DD77850370C46325D987CB525569FB63C5D3BC53950E6D4C5F174E25A1EE9017B5D450606ADD152B534931D7D4E8455CC91F9B15BF05EC36E377FA"
                "00617CCE7CF5064806C467F678D3B4080D6F1CC50AF26CA209417308281B68AF282623EAA63E5B5C0723D8B8C37FF0777B1A20F8CCB1DCCC43997F1EE0E44DA4A67A"
            )
        );
    }

    mod sign {
        use crate::{NistP521, test_vectors::ecdsa::ECDSA_TEST_VECTORS};
        ecdsa_core::new_signing_test!(NistP521, ECDSA_TEST_VECTORS);
    }

    mod verify {
        use crate::{NistP521, test_vectors::ecdsa::ECDSA_TEST_VECTORS};
        ecdsa_core::new_verification_test!(NistP521, ECDSA_TEST_VECTORS);
    }

    mod wycheproof {
        use crate::NistP521;
        ecdsa_core::new_wycheproof_test!(wycheproof, "wycheproof", NistP521);
    }
}
