use super::*;

#[test]
fn credential_grant_clear_sensitive_drops_user_material() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let grant = payload.credential_grant.as_mut().expect("credential grant");

    grant.clear_sensitive();

    assert!(grant.username.is_empty());
    assert!(grant.password.is_empty());
    assert!(grant.credential_secret_ref.is_empty());
}

#[test]
fn sensitive_string_debug_is_redacted() {
    let secret = SensitiveString::from("secret".to_string());

    assert_eq!(format!("{secret:?}"), "<redacted>");
}

#[test]
fn sensitive_string_expose_rejects_invalid_utf8() {
    let secret = SensitiveString { value: vec![0xff] };

    assert!(secret.expose().is_err());
}
