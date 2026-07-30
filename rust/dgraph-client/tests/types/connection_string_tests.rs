/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{ConnectionString, ConnectionStringErrorEnum, TlsMode};

#[test]
fn parses_minimal_connection_string() {
    let cs = ConnectionString::parse("dgraph://localhost:9080").expect("should parse");

    assert_eq!(cs.host(), "localhost");
    assert_eq!(cs.port(), 9080);
    // Empty sslmode defaults to plaintext, matching the Go client.
    assert_eq!(cs.tls_mode(), TlsMode::Disable);
    assert!(cs.username().is_none());
    assert!(cs.password().is_none());
    assert!(cs.namespace().is_none());
}

#[test]
fn parses_full_connection_string() {
    let cs = ConnectionString::parse(
        "dgraph://groot:password@alpha.example:9080?sslmode=verify-ca&namespace=3",
    )
    .expect("should parse");

    assert_eq!(cs.host(), "alpha.example");
    assert_eq!(cs.port(), 9080);
    assert_eq!(cs.tls_mode(), TlsMode::VerifyCa);
    assert_eq!(cs.username(), Some("groot"));
    assert_eq!(cs.password().map(|p| p.expose()), Some("password"));
    assert_eq!(cs.namespace(), Some(3));
}

// The Go client rejects this: open.go:170 requires exactly two colon-separated parts.
#[test]
fn parses_ipv6_literal() {
    let cs = ConnectionString::parse("dgraph://[::1]:9080").expect("IPv6 should parse");

    assert_eq!(cs.host(), "::1");
    assert_eq!(cs.port(), 9080);
    // Round-trips with brackets restored so it can be handed to a gRPC endpoint.
    assert_eq!(cs.authority(), "[::1]:9080");
}

#[test]
fn parses_full_ipv6_literal() {
    let cs = ConnectionString::parse("dgraph://[2001:db8::8a2e:370:7334]:9080")
        .expect("IPv6 should parse");

    assert_eq!(cs.host(), "2001:db8::8a2e:370:7334");
    assert_eq!(cs.port(), 9080);
}

#[test]
fn ipv4_authority_round_trips_without_brackets() {
    let cs = ConnectionString::parse("dgraph://127.0.0.1:9080").expect("should parse");

    assert_eq!(cs.authority(), "127.0.0.1:9080");
}

#[test]
fn rejects_unterminated_ipv6_literal() {
    let err = ConnectionString::parse("dgraph://[::1:9080").expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::MalformedAuthority(_)
    ));
}

#[test]
fn rejects_invalid_scheme() {
    let err = ConnectionString::parse("http://localhost:9080").expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::InvalidScheme(scheme) if scheme == "http"
    ));
}

#[test]
fn rejects_missing_scheme_separator() {
    let err = ConnectionString::parse("localhost:9080").expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::InvalidScheme(_)
    ));
}

#[test]
fn rejects_missing_port() {
    let err = ConnectionString::parse("dgraph://localhost").expect_err("should reject");
    assert!(matches!(err.kind(), ConnectionStringErrorEnum::MissingPort));

    let err = ConnectionString::parse("dgraph://localhost:").expect_err("should reject");
    assert!(matches!(err.kind(), ConnectionStringErrorEnum::MissingPort));
}

#[test]
fn rejects_missing_host() {
    let err = ConnectionString::parse("dgraph://:9080").expect_err("should reject");

    assert!(matches!(err.kind(), ConnectionStringErrorEnum::MissingHost));
}

#[test]
fn rejects_non_numeric_port() {
    let err = ConnectionString::parse("dgraph://localhost:abc").expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::InvalidPort(_)
    ));
}

#[test]
fn rejects_out_of_range_port() {
    let err = ConnectionString::parse("dgraph://localhost:70000").expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::InvalidPort(_)
    ));
}

#[test]
fn rejects_conflicting_auth_parameters() {
    let err = ConnectionString::parse("dgraph://localhost:9080?apikey=a&bearertoken=b")
        .expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::ConflictingAuth
    ));
}

#[test]
fn rejects_unknown_ssl_mode() {
    let err = ConnectionString::parse("dgraph://localhost:9080?sslmode=verify-full")
        .expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::UnknownSslMode(mode) if mode == "verify-full"
    ));
}

#[test]
fn rejects_incomplete_credentials() {
    let err = ConnectionString::parse("dgraph://groot@localhost:9080").expect_err("should reject");
    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::IncompleteCredentials
    ));

    let err = ConnectionString::parse("dgraph://:pw@localhost:9080").expect_err("should reject");
    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::IncompleteCredentials
    ));
}

#[test]
fn rejects_invalid_namespace() {
    let err = ConnectionString::parse("dgraph://localhost:9080?namespace=abc")
        .expect_err("should reject");

    assert!(matches!(
        err.kind(),
        ConnectionStringErrorEnum::InvalidNamespace(_)
    ));
}

#[test]
fn accepts_all_ssl_modes() {
    let disable = ConnectionString::parse("dgraph://h:1?sslmode=disable").expect("parses");
    assert_eq!(disable.tls_mode(), TlsMode::Disable);

    let require = ConnectionString::parse("dgraph://h:1?sslmode=require").expect("parses");
    assert_eq!(require.tls_mode(), TlsMode::RequireNoVerify);

    let verify = ConnectionString::parse("dgraph://h:1?sslmode=verify-ca").expect("parses");
    assert_eq!(verify.tls_mode(), TlsMode::VerifyCa);
}

#[test]
fn decodes_percent_encoded_credentials() {
    let cs = ConnectionString::parse("dgraph://user%40corp:p%40ss%3Aword@localhost:9080")
        .expect("should parse");

    assert_eq!(cs.username(), Some("user@corp"));
    assert_eq!(cs.password().map(|p| p.expose()), Some("p@ss:word"));
}

// A '@' inside a query value must not be mistaken for the userinfo separator.
#[test]
fn at_sign_in_query_value_is_not_userinfo() {
    let cs = ConnectionString::parse("dgraph://localhost:9080?bearertoken=abc@def")
        .expect("should parse");

    assert_eq!(cs.host(), "localhost");
    assert!(cs.username().is_none());
    assert_eq!(cs.bearer_token().map(|t| t.expose()), Some("abc@def"));
}

#[test]
fn unknown_query_parameters_are_ignored() {
    let cs =
        ConnectionString::parse("dgraph://localhost:9080?unknown=value").expect("should parse");

    assert_eq!(cs.host(), "localhost");
}

#[test]
fn scheme_is_case_insensitive() {
    let cs = ConnectionString::parse("DGRAPH://localhost:9080").expect("should parse");

    assert_eq!(cs.host(), "localhost");
}

// Spec: a parse failure must never echo credential material.
#[test]
fn parse_failure_does_not_leak_credentials() {
    let err = ConnectionString::parse("http://groot:sup3rs3cret@localhost:9080")
        .expect_err("should reject");

    let rendered = format!("{err}");
    assert!(
        !rendered.contains("sup3rs3cret"),
        "leaked in Display: {rendered}"
    );

    let debugged = format!("{err:?}");
    assert!(
        !debugged.contains("sup3rs3cret"),
        "leaked in Debug: {debugged}"
    );
}

// Spec: Debug on the parsed value must redact every credential.
#[test]
fn debug_redacts_all_credentials() {
    let cs = ConnectionString::parse("dgraph://groot:sup3rs3cret@localhost:9080?apikey=k3y")
        .expect("should parse");

    let debugged = format!("{cs:?}");
    assert!(
        !debugged.contains("sup3rs3cret"),
        "password leaked: {debugged}"
    );
    assert!(!debugged.contains("k3y"), "api key leaked: {debugged}");
    // Non-secret fields stay visible so the value is still debuggable.
    assert!(debugged.contains("localhost"));
    assert!(debugged.contains("groot"));
}

#[test]
fn parses_via_from_str() {
    let cs: ConnectionString = "dgraph://localhost:9080".parse().expect("should parse");

    assert_eq!(cs.port(), 9080);
}
