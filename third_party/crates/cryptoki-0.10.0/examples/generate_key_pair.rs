// Copyright 2024 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
use cryptoki::context::{CInitializeArgs, Pkcs11};
use cryptoki::mechanism::Mechanism;
use cryptoki::object::Attribute;
use cryptoki::session::UserType;
use cryptoki::types::AuthPin;
use std::env;

// The default user pin
pub static USER_PIN: &str = "fedcba";
// The default SO pin
pub static SO_PIN: &str = "abcdef";

fn main() -> testresult::TestResult {
    // initialize a new Pkcs11 object using the module from the env variable
    let pkcs11 = Pkcs11::new(
        env::var("TEST_PKCS11_MODULE")
            .unwrap_or_else(|_| "/usr/local/lib/softhsm/libsofthsm2.so".to_string()),
    )?;

    pkcs11.initialize(CInitializeArgs::OsThreads)?;

    let slot = pkcs11.get_slots_with_token()?[0];

    // initialize a test token
    let so_pin = AuthPin::new("abcdef".into());
    pkcs11.init_token(slot, &so_pin, "Test Token")?;

    let user_pin = AuthPin::new("fedcba".into());

    // initialize user PIN
    {
        let session = pkcs11.open_rw_session(slot)?;
        session.login(UserType::So, Some(&so_pin))?;
        session.init_pin(&user_pin)?;
    }

    // login as a user, the token has to be already initialized
    let session = pkcs11.open_rw_session(slot)?;
    session.login(UserType::User, Some(&user_pin))?;

    // template of the public key
    let pub_key_template = vec![
        Attribute::Token(true),
        Attribute::Private(false),
        Attribute::PublicExponent(vec![0x01, 0x00, 0x01]),
        Attribute::ModulusBits(1024.into()),
    ];

    let priv_key_template = vec![Attribute::Token(true)];

    // generate an RSA key according to passed templates
    let (_public, _private) = session.generate_key_pair(
        &Mechanism::RsaPkcsKeyPairGen,
        &pub_key_template,
        &priv_key_template,
    )?;
    Ok(())
}
