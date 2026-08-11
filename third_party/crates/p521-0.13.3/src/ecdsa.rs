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
//! use rand_core::OsRng; // requires 'getrandom' feature
//!
//! // Signing
//! let signing_key = SigningKey::random(&mut OsRng); // Serialize with `::to_bytes()`
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

// TODO(tarcieri): use RFC6979 + upstream types from the `ecdsa` crate

pub use ecdsa_core::signature::{self, Error, Result};

#[cfg(feature = "ecdsa")]
use {
    crate::{AffinePoint, EncodedPoint, FieldBytes, NonZeroScalar, Scalar},
    ecdsa_core::{
        hazmat::{bits2field, sign_prehashed, SignPrimitive, VerifyPrimitive},
        signature::{
            hazmat::{PrehashVerifier, RandomizedPrehashSigner},
            rand_core::CryptoRngCore,
            RandomizedSigner, Verifier,
        },
    },
    elliptic_curve::Field,
    sha2::{Digest, Sha512},
};

#[cfg(all(feature = "ecdsa", feature = "getrandom"))]
use {
    ecdsa_core::signature::{hazmat::PrehashSigner, Signer},
    rand_core::OsRng,
};

use super::NistP521;

/// ECDSA/P-521 signature (fixed-size)
pub type Signature = ecdsa_core::Signature<NistP521>;

/// ECDSA/P-521 signature (ASN.1 DER encoded)
pub type DerSignature = ecdsa_core::der::Signature<NistP521>;

#[cfg(feature = "ecdsa")]
impl SignPrimitive<NistP521> for Scalar {}

#[cfg(feature = "ecdsa")]
impl VerifyPrimitive<NistP521> for AffinePoint {}

/// ECDSA/P-521 signing key
#[cfg(feature = "ecdsa")]
#[derive(Clone)]
pub struct SigningKey(ecdsa_core::SigningKey<NistP521>);

#[cfg(feature = "ecdsa")]
impl SigningKey {
    /// Generate a cryptographically random [`SigningKey`].
    pub fn random(rng: &mut impl CryptoRngCore) -> Self {
        ecdsa_core::SigningKey::<NistP521>::random(rng).into()
    }

    /// Initialize signing key from a raw scalar serialized as a byte array.
    pub fn from_bytes(bytes: &FieldBytes) -> Result<Self> {
        ecdsa_core::SigningKey::<NistP521>::from_bytes(bytes).map(Into::into)
    }

    /// Initialize signing key from a raw scalar serialized as a byte slice.
    pub fn from_slice(bytes: &[u8]) -> Result<Self> {
        ecdsa_core::SigningKey::<NistP521>::from_slice(bytes).map(Into::into)
    }

    /// Serialize this [`SigningKey`] as bytes
    pub fn to_bytes(&self) -> FieldBytes {
        self.0.to_bytes()
    }

    /// Borrow the secret [`NonZeroScalar`] value for this key.
    ///
    /// # ⚠️ Warning
    ///
    /// This value is key material.
    ///
    /// Please treat it with the care it deserves!
    pub fn as_nonzero_scalar(&self) -> &NonZeroScalar {
        self.0.as_nonzero_scalar()
    }

    /// Get the [`VerifyingKey`] which corresponds to this [`SigningKey`].
    #[cfg(feature = "verifying")]
    pub fn verifying_key(&self) -> VerifyingKey {
        VerifyingKey::from(self)
    }
}

#[cfg(feature = "ecdsa")]
impl From<ecdsa_core::SigningKey<NistP521>> for SigningKey {
    fn from(inner: ecdsa_core::SigningKey<NistP521>) -> SigningKey {
        SigningKey(inner)
    }
}

#[cfg(all(feature = "ecdsa", feature = "getrandom"))]
impl PrehashSigner<Signature> for SigningKey {
    fn sign_prehash(&self, prehash: &[u8]) -> Result<Signature> {
        self.sign_prehash_with_rng(&mut OsRng, prehash)
    }
}

#[cfg(feature = "ecdsa")]
impl RandomizedPrehashSigner<Signature> for SigningKey {
    fn sign_prehash_with_rng(
        &self,
        rng: &mut impl CryptoRngCore,
        prehash: &[u8],
    ) -> Result<Signature> {
        let z = bits2field::<NistP521>(prehash)?;
        let k = Scalar::random(rng);
        sign_prehashed(self.0.as_nonzero_scalar().as_ref(), k, &z).map(|sig| sig.0)
    }
}

#[cfg(feature = "ecdsa")]
impl RandomizedSigner<Signature> for SigningKey {
    fn try_sign_with_rng(&self, rng: &mut impl CryptoRngCore, msg: &[u8]) -> Result<Signature> {
        self.sign_prehash_with_rng(rng, &Sha512::digest(msg))
    }
}

#[cfg(all(feature = "ecdsa", feature = "getrandom"))]
impl Signer<Signature> for SigningKey {
    fn try_sign(&self, msg: &[u8]) -> Result<Signature> {
        self.try_sign_with_rng(&mut OsRng, msg)
    }
}

/// ECDSA/P-521 verification key (i.e. public key)
#[cfg(feature = "ecdsa")]
#[derive(Clone)]
pub struct VerifyingKey(ecdsa_core::VerifyingKey<NistP521>);

#[cfg(feature = "ecdsa")]
impl VerifyingKey {
    /// Initialize [`VerifyingKey`] from a SEC1-encoded public key.
    pub fn from_sec1_bytes(bytes: &[u8]) -> Result<Self> {
        ecdsa_core::VerifyingKey::<NistP521>::from_sec1_bytes(bytes).map(Into::into)
    }

    /// Initialize [`VerifyingKey`] from an affine point.
    ///
    /// Returns an [`Error`] if the given affine point is the additive identity
    /// (a.k.a. point at infinity).
    pub fn from_affine(affine: AffinePoint) -> Result<Self> {
        ecdsa_core::VerifyingKey::<NistP521>::from_affine(affine).map(Into::into)
    }

    /// Initialize [`VerifyingKey`] from an [`EncodedPoint`].
    pub fn from_encoded_point(public_key: &EncodedPoint) -> Result<Self> {
        ecdsa_core::VerifyingKey::<NistP521>::from_encoded_point(public_key).map(Into::into)
    }

    /// Serialize this [`VerifyingKey`] as a SEC1 [`EncodedPoint`], optionally
    /// applying point compression.
    pub fn to_encoded_point(&self, compress: bool) -> EncodedPoint {
        self.0.to_encoded_point(compress)
    }

    /// Borrow the inner [`AffinePoint`] for this public key.
    pub fn as_affine(&self) -> &AffinePoint {
        self.0.as_affine()
    }
}

#[cfg(feature = "ecdsa")]
impl From<&SigningKey> for VerifyingKey {
    fn from(signing_key: &SigningKey) -> VerifyingKey {
        Self::from(*signing_key.0.verifying_key())
    }
}

#[cfg(feature = "ecdsa")]
impl From<ecdsa_core::VerifyingKey<NistP521>> for VerifyingKey {
    fn from(inner: ecdsa_core::VerifyingKey<NistP521>) -> VerifyingKey {
        VerifyingKey(inner)
    }
}

#[cfg(feature = "ecdsa")]
impl PrehashVerifier<Signature> for VerifyingKey {
    fn verify_prehash(&self, prehash: &[u8], signature: &Signature) -> Result<()> {
        self.0.verify_prehash(prehash, signature)
    }
}

#[cfg(feature = "ecdsa")]
impl Verifier<Signature> for VerifyingKey {
    fn verify(&self, msg: &[u8], signature: &Signature) -> Result<()> {
        self.verify_prehash(&Sha512::digest(msg), signature)
    }
}

#[cfg(all(test, feature = "ecdsa", feature = "getrandom"))]
mod tests {
    // TODO(tarcieri): RFC6979 support + test vectors

    mod sign {
        use crate::{test_vectors::ecdsa::ECDSA_TEST_VECTORS, NistP521};
        ecdsa_core::new_signing_test!(NistP521, ECDSA_TEST_VECTORS);
    }

    mod verify {
        use crate::{test_vectors::ecdsa::ECDSA_TEST_VECTORS, NistP521};
        ecdsa_core::new_verification_test!(NistP521, ECDSA_TEST_VECTORS);
    }

    mod wycheproof {
        use crate::{
            ecdsa::{Signature, Verifier, VerifyingKey},
            EncodedPoint, NistP521,
        };

        // TODO: use ecdsa_core::new_wycheproof_test!(wycheproof, "wycheproof", NistP521);
        #[test]
        fn wycheproof() {
            use blobby::Blob5Iterator;
            use elliptic_curve::generic_array::typenum::Unsigned;

            // Build a field element but allow for too-short input (left pad with zeros)
            // or too-long input (check excess leftmost bytes are zeros).
            fn element_from_padded_slice<C: elliptic_curve::Curve>(
                data: &[u8],
            ) -> elliptic_curve::FieldBytes<C> {
                let point_len = C::FieldBytesSize::USIZE;
                if data.len() >= point_len {
                    let offset = data.len() - point_len;
                    for v in data.iter().take(offset) {
                        assert_eq!(*v, 0, "EcdsaVerifier: point too large");
                    }
                    elliptic_curve::FieldBytes::<C>::clone_from_slice(&data[offset..])
                } else {
                    // Provided slice is too short and needs to be padded with zeros
                    // on the left.  Build a combined exact iterator to do this.
                    let iter = core::iter::repeat(0)
                        .take(point_len - data.len())
                        .chain(data.iter().cloned());
                    elliptic_curve::FieldBytes::<C>::from_exact_iter(iter).unwrap()
                }
            }

            fn run_test(
                wx: &[u8],
                wy: &[u8],
                msg: &[u8],
                sig: &[u8],
                pass: bool,
            ) -> Option<&'static str> {
                let x = element_from_padded_slice::<NistP521>(wx);
                let y = element_from_padded_slice::<NistP521>(wy);
                let q_encoded =
                    EncodedPoint::from_affine_coordinates(&x, &y, /* compress= */ false);
                let verifying_key = VerifyingKey::from_encoded_point(&q_encoded).unwrap();

                let sig = match Signature::from_der(sig) {
                    Ok(s) => s,
                    Err(_) if !pass => return None,
                    Err(_) => return Some("failed to parse signature ASN.1"),
                };

                match verifying_key.verify(msg, &sig) {
                    Ok(_) if pass => None,
                    Ok(_) => Some("signature verify unexpectedly succeeded"),
                    Err(_) if !pass => None,
                    Err(_) => Some("signature verify failed"),
                }
            }

            let data = include_bytes!(concat!("test_vectors/data/wycheproof.blb"));

            for (i, row) in Blob5Iterator::new(data).unwrap().enumerate() {
                let [wx, wy, msg, sig, status] = row.unwrap();
                let pass = match status[0] {
                    0 => false,
                    1 => true,
                    _ => panic!("invalid value for pass flag"),
                };
                if let Some(desc) = run_test(wx, wy, msg, sig, pass) {
                    panic!(
                        "\n\
                                 Failed test №{}: {}\n\
                                 wx:\t{:?}\n\
                                 wy:\t{:?}\n\
                                 msg:\t{:?}\n\
                                 sig:\t{:?}\n\
                                 pass:\t{}\n",
                        i, desc, wx, wy, msg, sig, pass,
                    );
                }
            }
        }
    }
}
