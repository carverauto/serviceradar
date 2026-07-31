/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::TlsMode;

#[test]
fn default_is_plaintext() {
    assert_eq!(TlsMode::default(), TlsMode::Disable);
}

#[test]
fn reports_whether_tls_is_used() {
    assert!(!TlsMode::Disable.is_tls());
    assert!(TlsMode::RequireNoVerify.is_tls());
    assert!(TlsMode::VerifyCa.is_tls());
}

// The whole point of the RequireNoVerify name: it is encrypted but unauthenticated.
#[test]
fn only_verify_ca_authenticates_the_server() {
    assert!(!TlsMode::Disable.verifies_certificate());
    assert!(!TlsMode::RequireNoVerify.verifies_certificate());
    assert!(TlsMode::VerifyCa.verifies_certificate());
}
