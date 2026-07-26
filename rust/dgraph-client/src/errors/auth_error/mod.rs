/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod auth_error_display;
mod auth_error_error;

use tonic::Code;

/// Failure of an authentication or token-refresh operation.
///
/// The wrapped classification is private; branch on [`AuthError::kind`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AuthError(AuthErrorEnum);

/// Detailed classification of authentication errors.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum AuthErrorEnum {
    /// The login RPC failed.
    LoginFailed { code: Code, message: String },
    /// A token refresh was required but no refresh token is cached.
    ///
    /// The failure that triggered the refresh is retained. The Go client discards it and
    /// surfaces only "refresh jwt should not be empty", which hides the real cause.
    MissingRefreshToken {
        original_code: Code,
        original_message: String,
    },
    /// The refresh RPC itself failed. Both the refresh failure and the failure that
    /// triggered it are retained.
    RefreshFailed {
        code: Code,
        message: String,
        original_code: Code,
        original_message: String,
    },
    /// The login response payload could not be decoded.
    ///
    /// The payload is protobuf-encoded despite the wire field being named `json`.
    MalformedJwtPayload(String),
}

impl AuthError {
    pub(crate) fn new(variant: AuthErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    pub fn kind(&self) -> &AuthErrorEnum {
        &self.0
    }

    #[allow(non_snake_case)]
    pub fn LoginFailed(code: Code, message: String) -> Self {
        Self::new(AuthErrorEnum::LoginFailed { code, message })
    }

    #[allow(non_snake_case)]
    pub fn MissingRefreshToken(original_code: Code, original_message: String) -> Self {
        Self::new(AuthErrorEnum::MissingRefreshToken {
            original_code,
            original_message,
        })
    }

    #[allow(non_snake_case)]
    pub fn RefreshFailed(
        code: Code,
        message: String,
        original_code: Code,
        original_message: String,
    ) -> Self {
        Self::new(AuthErrorEnum::RefreshFailed {
            code,
            message,
            original_code,
            original_message,
        })
    }

    #[allow(non_snake_case)]
    pub fn MalformedJwtPayload(msg: String) -> Self {
        Self::new(AuthErrorEnum::MalformedJwtPayload(msg))
    }
}
