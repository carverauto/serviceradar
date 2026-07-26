/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Display, Formatter};

use super::{AuthError, AuthErrorEnum};

// Never renders a password or token: only server-supplied status text is included, and no
// variant of this type carries credential material.
impl Display for AuthError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match self.kind() {
            AuthErrorEnum::LoginFailed { code, message } => {
                write!(f, "Login Failed: {code:?}: {message}")
            }
            AuthErrorEnum::MissingRefreshToken {
                original_code,
                original_message,
            } => write!(
                f,
                "Missing Refresh Token: a token refresh was required but none is cached \
                 (triggered by {original_code:?}: {original_message})"
            ),
            AuthErrorEnum::RefreshFailed {
                code,
                message,
                original_code,
                original_message,
            } => write!(
                f,
                "Refresh Failed: {code:?}: {message} (triggered by {original_code:?}: \
                 {original_message})"
            ),
            AuthErrorEnum::MalformedJwtPayload(msg) => {
                write!(f, "Malformed JWT Payload: {msg}")
            }
        }
    }
}
