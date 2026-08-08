/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod secret_debug;
mod secret_display;

/// A credential that must never be rendered.
///
/// `Debug` and `Display` are implemented by hand to print a fixed redaction marker, so a
/// secret cannot reach a log line, a panic message, or an error string by accident. The
/// value is only reachable through [`Secret::expose`], which is deliberately verbose at
/// the call site.
///
/// `PartialEq` is derived rather than constant-time: these values are compared only
/// against locally held copies in tests, never against attacker-supplied input.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Secret(String);

impl Secret {
    /// Wrap a credential.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// The underlying credential.
    ///
    /// Named `expose` so that every use is obvious in review. Do not pass the result to
    /// anything that formats it.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Whether the credential is empty.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}
