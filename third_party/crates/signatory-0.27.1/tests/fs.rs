//! Filesystem keystore integration test

#![cfg(feature = "secp256k1")]

use signatory::{
    ecdsa::secp256k1::{Signature, SigningKey},
    signature::{Signer, Verifier},
    FsKeyStore, GeneratePkcs8, KeyName, KeyRing,
};

/// Integration test for loading a key from a keystore
#[test]
fn integration() {
    let dir = tempfile::tempdir().unwrap();
    let key_store = FsKeyStore::create_or_open(&dir.path()).unwrap();
    let example_key = SigningKey::generate_pkcs8();

    let key_name = "example".parse::<KeyName>().unwrap();
    key_store.store(&key_name, &example_key).unwrap();

    let mut key_ring = KeyRing::new();
    let key_handle = key_store.import(&key_name, &mut key_ring).unwrap();

    let signing_key = key_ring.ecdsa.secp256k1.iter().next().unwrap();
    let verifying_key = key_handle.ecdsa_secp256k1().unwrap();
    assert_eq!(signing_key.verifying_key(), verifying_key);

    let example_message = "Hello, world!";
    let signature: Signature = signing_key.sign(example_message.as_bytes());
    assert!(verifying_key
        .verify(example_message.as_bytes(), &signature)
        .is_ok());
}
