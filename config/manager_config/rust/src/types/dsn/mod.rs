//! An assembled connection string.

/// A PostgreSQL DSN, which cannot be printed.
///
/// The DSN is NOT a schema field precisely because it embeds a password (see config.proto). That
/// reasoning does not stop at the schema: an assembled DSN is as sensitive as the secret inside
/// it, so returning a bare `String` here would undo the redaction SecretManager provides and put
/// the credential back into the first `{:?}` that touches it.
#[derive(Clone, PartialEq, Eq)]
pub struct Dsn {
    value: String,
}

impl Dsn {
    pub(crate) fn new(value: String) -> Self {
        Self { value }
    }

    /// The connection string. Named so that reading it is visible in review and greppable.
    pub fn expose(&self) -> &str {
        &self.value
    }
}

mod dsn_debug;
mod dsn_display;

/// What a redacted DSN renders as.
pub const REDACTED: &str = "[REDACTED DSN]";
