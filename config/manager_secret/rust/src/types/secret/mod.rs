//! A resolved secret value.

/// A secret, which cannot be printed.
///
/// `Debug` and `Display` are hand-written to redact, and the value is reachable only through
/// [`Secret::expose`]. That name is the point: every call site that reads the value says so, and
/// a grep for `expose` is the complete list of places a secret can leave this type.
///
/// The default derives are deliberately NOT used. A derived `Debug` puts the value into any
/// `{:?}` -- a tracing span, an `unwrap` panic, an error chain -- and none of those look like
/// logging a password at the call site.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret {
    value: String,
}

impl Secret {
    /// Wraps a resolved value.
    ///
    /// Empty is not a secret: a provider that returns an empty string has failed to resolve one,
    /// and treating it as a value is how a component connects with a blank password.
    pub fn new(value: impl Into<String>) -> Option<Self> {
        let value = value.into();
        if value.is_empty() {
            None
        } else {
            Some(Self { value })
        }
    }

    /// The value. Named so that reading it is visible in review and greppable in audit.
    pub fn expose(&self) -> &str {
        &self.value
    }

    pub fn len(&self) -> usize {
        self.value.len()
    }

    pub fn is_empty(&self) -> bool {
        // Unreachable by construction; present so `len` does not stand alone.
        self.value.is_empty()
    }
}

mod secret_debug;
mod secret_display;

/// What a redacted secret renders as, in both `Debug` and `Display`.
pub const REDACTED: &str = "[REDACTED]";
