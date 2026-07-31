/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{AuthError, AuthErrorEnum};
use tonic::Code;

// The Go client discards the triggering failure and surfaces only "refresh jwt should not
// be empty", which hides the real cause. Both must survive here.
#[test]
fn missing_refresh_token_retains_the_triggering_failure() {
    let err = AuthError::MissingRefreshToken(Code::Unauthenticated, "Token is expired".to_string());

    match err.kind() {
        AuthErrorEnum::MissingRefreshToken {
            original_code,
            original_message,
        } => {
            assert_eq!(*original_code, Code::Unauthenticated);
            assert_eq!(original_message, "Token is expired");
        }
        other => panic!("unexpected classification: {other:?}"),
    }
}

#[test]
fn refresh_failed_retains_both_failures() {
    let err = AuthError::RefreshFailed(
        Code::Unavailable,
        "alpha down".to_string(),
        Code::Unauthenticated,
        "Token is expired".to_string(),
    );

    let rendered = format!("{err}");
    assert!(rendered.contains("alpha down"));
    assert!(rendered.contains("Token is expired"));
}

#[test]
fn constructors_produce_matching_classification() {
    assert!(matches!(
        AuthError::MalformedJwtPayload("bad".to_string()).kind(),
        AuthErrorEnum::MalformedJwtPayload(_)
    ));
}
