//! Trait for verifying digital signatures

use crate::error::Error;

#[cfg(feature = "digest")]
use crate::digest::Update;

/// Verify the provided message bytestring using `Self` (e.g. a public key)
pub trait Verifier<S> {
    /// Use `Self` to verify that the provided signature for a given message
    /// bytestring is authentic.
    ///
    /// Returns `Error` if it is inauthentic, or otherwise returns `()`.
    fn verify(&self, msg: &[u8], signature: &S) -> Result<(), Error>;
}

/// Equivalent of [`Verifier`] but the message is provided in non-contiguous byte slices.
pub trait MultipartVerifier<S> {
    /// Equivalent of [`Verifier::verify()`] but the
    /// message is provided in non-contiguous byte slices.
    fn multipart_verify(&self, msg: &[&[u8]], signature: &S) -> Result<(), Error>;
}

/// Verify the provided signature for the given prehashed message `Digest`
/// is authentic.
///
/// ## Notes
///
/// This trait is primarily intended for signature algorithms based on the
/// [Fiat-Shamir heuristic], a method for converting an interactive
/// challenge/response-based proof-of-knowledge protocol into an offline
/// digital signature through the use of a random oracle, i.e. a digest
/// function.
///
/// The security of such protocols critically rests upon the inability of
/// an attacker to solve for the output of the random oracle, as generally
/// otherwise such signature algorithms are a system of linear equations and
/// therefore doing so would allow the attacker to trivially forge signatures.
///
/// To prevent misuse which would potentially allow this to be possible, this
/// API accepts a message by updating the received `Digest` with it, rather
/// than a raw digest value.
///
/// [Fiat-Shamir heuristic]: https://en.wikipedia.org/wiki/Fiat%E2%80%93Shamir_heuristic
#[cfg(feature = "digest")]
pub trait DigestVerifier<D: Update, S> {
    /// Verify the signature against the received `Digest` output,
    /// by updating it with the message.
    ///
    /// The given function can be invoked multiple times. It is expected that
    /// in each invocation the `Digest` is updated with the entire equal message.
    fn verify_digest<F: Fn(&mut D) -> Result<(), Error>>(
        &self,
        f: F,
        signature: &S,
    ) -> Result<(), Error>;
}
