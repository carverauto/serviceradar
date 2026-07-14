//! Ed25519 digital signature algorithm support.

mod keyring;
mod sign;
mod verify;

pub use self::{
    keyring::KeyRing,
    sign::{Ed25519Signer, SigningKey},
    verify::VerifyingKey,
};
pub use ed25519_dalek::ed25519::Signature;

/// Ed25519 Object Identifier (OID).
pub const ALGORITHM_OID: pkcs8::ObjectIdentifier =
    pkcs8::ObjectIdentifier::new_unwrap("1.3.101.112");

/// Ed25519 Algorithm Identifier.
pub const ALGORITHM_ID: pkcs8::AlgorithmIdentifierRef<'static> = pkcs8::AlgorithmIdentifierRef {
    oid: ALGORITHM_OID,
    parameters: None,
};
