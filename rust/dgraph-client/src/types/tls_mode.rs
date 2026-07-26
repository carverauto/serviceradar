/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

/// Transport security for a connection.
///
/// Named after what each mode actually does rather than after the wire value, because
/// `sslmode=require` is easy to misread as "secure".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TlsMode {
    /// Plaintext. Wire value `disable`. This is the default, matching the Go client.
    #[default]
    Disable,
    /// TLS with certificate verification DISABLED. Wire value `require`.
    ///
    /// The connection is encrypted but the server is not authenticated, so it does not
    /// protect against an active attacker. Selecting this emits a warning at connect
    /// time. Prefer [`TlsMode::VerifyCa`].
    RequireNoVerify,
    /// TLS verified against the system certificate roots. Wire value `verify-ca`.
    VerifyCa,
}

impl TlsMode {
    /// Parse the `sslmode` query parameter. An empty value means [`TlsMode::Disable`].
    pub(crate) fn from_wire(value: &str) -> Option<Self> {
        match value {
            "" | "disable" => Some(Self::Disable),
            "require" => Some(Self::RequireNoVerify),
            "verify-ca" => Some(Self::VerifyCa),
            _ => None,
        }
    }

    /// Whether this mode establishes a TLS session at all.
    pub fn is_tls(&self) -> bool {
        !matches!(self, Self::Disable)
    }

    /// Whether the server certificate is verified.
    pub fn verifies_certificate(&self) -> bool {
        matches!(self, Self::VerifyCa)
    }
}
