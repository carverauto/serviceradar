// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
use cryptoki::context::{CInitializeArgs, Pkcs11};
use cryptoki::session::UserType;
use cryptoki::slot::Slot;
use cryptoki::types::AuthPin;
use std::env;

// The default user pin
pub static USER_PIN: &str = "fedcba";
// The default SO pin
pub static SO_PIN: &str = "abcdef";

fn get_pkcs11_path() -> String {
    env::var("TEST_PKCS11_MODULE")
        .unwrap_or_else(|_| "/usr/local/lib/softhsm/libsofthsm2.so".to_string())
}

pub fn is_softhsm() -> bool {
    get_pkcs11_path().contains("softhsm")
}

pub fn get_pkcs11() -> Pkcs11 {
    Pkcs11::new(get_pkcs11_path()).unwrap()
}

pub fn init_pins() -> (Pkcs11, Slot) {
    let pkcs11 = get_pkcs11();

    // initialize the library
    pkcs11.initialize(CInitializeArgs::OsThreads).unwrap();

    // find a slot, get the first one
    let slot = pkcs11.get_slots_with_token().unwrap().remove(0);

    let so_pin = AuthPin::new(SO_PIN.into());
    pkcs11.init_token(slot, &so_pin, "Test Token").unwrap();

    {
        // open a session
        let session = pkcs11.open_rw_session(slot).unwrap();
        // log in the session
        session.login(UserType::So, Some(&so_pin)).unwrap();
        session.init_pin(&AuthPin::new(USER_PIN.into())).unwrap();
    }

    (pkcs11, slot)
}
