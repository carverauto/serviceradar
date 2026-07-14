//! Elliptic Curve Digital Signature Algorithm (ECDSA) support.

#[cfg(feature = "nistp256")]
pub mod nistp256;

#[cfg(feature = "nistp384")]
pub mod nistp384;

#[cfg(feature = "secp256k1")]
pub mod secp256k1;

mod keyring;

pub use self::keyring::KeyRing;
pub use ecdsa::{elliptic_curve, Signature};

#[cfg(feature = "nistp256")]
pub use {self::nistp256::NistP256Signer, p256::NistP256};

#[cfg(feature = "nistp384")]
pub use {self::nistp384::NistP384Signer, p384::NistP384};

#[cfg(feature = "secp256k1")]
pub use {self::secp256k1::Secp256k1Signer, k256::Secp256k1};
