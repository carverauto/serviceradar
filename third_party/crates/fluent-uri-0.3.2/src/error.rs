//! Error types.

use crate::internal::NoInput;

/// Detailed cause of a [`ParseError`].
#[derive(Clone, Copy, Debug)]
pub(crate) enum ParseErrorKind {
    /// Invalid percent-encoded octet that is either non-hexadecimal or incomplete.
    ///
    /// The error index points to the percent character "%" of the octet.
    InvalidOctet,
    /// Unexpected character that is not allowed by the URI/IRI syntax.
    ///
    /// The error index points to the first byte of the character.
    UnexpectedChar,
    /// Invalid IPv6 address.
    ///
    /// The error index points to the first byte of the address.
    InvalidIpv6Addr,
    /// The scheme component is not present.
    NoScheme,
}

/// An error occurred when parsing a URI/IRI (reference).
#[derive(Clone, Copy)]
pub struct ParseError<I = NoInput> {
    pub(crate) index: usize,
    pub(crate) kind: ParseErrorKind,
    pub(crate) input: I,
}

impl ParseError {
    pub(crate) fn with_input<I>(self, input: I) -> ParseError<I> {
        ParseError {
            index: self.index,
            kind: self.kind,
            input,
        }
    }
}

impl<I: AsRef<str>> ParseError<I> {
    /// Recovers the input that was attempted to parse into a URI/IRI (reference).
    #[must_use]
    pub fn into_input(self) -> I {
        self.input
    }

    /// Returns the error with the input stripped.
    #[must_use]
    pub fn strip_input(&self) -> ParseError {
        ParseError {
            index: self.index,
            kind: self.kind,
            input: NoInput,
        }
    }
}

#[cfg(feature = "std")]
impl<I> std::error::Error for ParseError<I> {}

/// Detailed cause of a [`BuildError`].
#[derive(Clone, Copy, Debug)]
pub(crate) enum BuildErrorKind {
    NonAbemptyPath,
    PathStartingWithDoubleSlash,
    ColonInFirstPathSegment,
}

/// An error occurred when building a URI/IRI (reference).
#[derive(Clone, Copy, Debug)]
pub struct BuildError(pub(crate) BuildErrorKind);

#[cfg(feature = "std")]
impl std::error::Error for BuildError {}

/// Detailed cause of a [`ResolveError`].
#[derive(Clone, Copy, Debug)]
pub(crate) enum ResolveErrorKind {
    InvalidBase,
    OpaqueBase,
    // PathUnderflow,
}

/// An error occurred when resolving a URI/IRI reference.
#[derive(Clone, Copy, Debug)]
pub struct ResolveError(pub(crate) ResolveErrorKind);

#[cfg(feature = "std")]
impl std::error::Error for ResolveError {}
