/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use core::fmt::{Display, Formatter};

use super::{ConnectionStringError, ConnectionStringErrorEnum};

// No part of this Display renders a password, api key, or bearer token: the parser only
// ever constructs these variants with structural detail, never with credential material.
impl Display for ConnectionStringError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match self.kind() {
            ConnectionStringErrorEnum::InvalidScheme(found) => {
                write!(f, "Invalid Scheme: expected dgraph://, found '{found}'")
            }
            ConnectionStringErrorEnum::MissingHost => {
                write!(f, "Missing Host: connection string has no host")
            }
            ConnectionStringErrorEnum::MissingPort => {
                write!(f, "Missing Port: connection string has no port")
            }
            ConnectionStringErrorEnum::MalformedAuthority(msg) => {
                write!(f, "Malformed Authority: {msg}")
            }
            ConnectionStringErrorEnum::InvalidPort(msg) => {
                write!(f, "Invalid Port: {msg}")
            }
            ConnectionStringErrorEnum::ConflictingAuth => write!(
                f,
                "Conflicting Auth: apikey and bearertoken are mutually exclusive"
            ),
            ConnectionStringErrorEnum::UnknownSslMode(found) => write!(
                f,
                "Unknown SSL Mode: '{found}' (must be one of disable, require, verify-ca)"
            ),
            ConnectionStringErrorEnum::IncompleteCredentials => write!(
                f,
                "Incomplete Credentials: both username and password must be provided"
            ),
            ConnectionStringErrorEnum::InvalidNamespace(msg) => {
                write!(f, "Invalid Namespace: {msg}")
            }
            ConnectionStringErrorEnum::InvalidPercentEncoding(msg) => {
                write!(f, "Invalid Percent Encoding: {msg}")
            }
            ConnectionStringErrorEnum::MalformedQuery(msg) => {
                write!(f, "Malformed Query: {msg}")
            }
        }
    }
}
