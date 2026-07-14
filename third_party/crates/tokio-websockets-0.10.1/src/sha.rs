//! Unified abstraction over all supported SHA-1 backends.
#[cfg(all(feature = "aws_lc_rs", not(feature = "openssl")))]
use aws_lc_rs::digest;
#[cfg(feature = "openssl")]
use openssl::sha::Sha1;
#[cfg(all(feature = "ring", not(feature = "aws_lc_rs"), not(feature = "openssl")))]
use ring::digest;
#[cfg(all(
    feature = "sha1_smol",
    not(feature = "ring"),
    not(feature = "aws_lc_rs"),
    not(feature = "openssl")
))]
use sha1_smol::Sha1;

/// The Globally Unique Identifier (GUID) used in the WebSocket protocol (see [the RFC](https://datatracker.ietf.org/doc/html/rfc6455#section-1.3)).
const GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Calculate the SHA-1 digest of a WebSocket key and the GUID using the
/// [`sha1_smol`] crate.
#[cfg(all(
    feature = "sha1_smol",
    not(feature = "aws_lc_rs"),
    not(feature = "ring"),
    not(feature = "openssl")
))]
pub fn digest(key: &[u8]) -> [u8; 20] {
    let mut s = Sha1::new();
    s.update(key);
    s.update(GUID.as_bytes());
    s.digest().bytes()
}

/// Calculate the SHA-1 digest of a WebSocket key and the GUID using the
/// [`ring`] crate.
#[cfg(all(feature = "ring", not(feature = "aws_lc_rs"), not(feature = "openssl")))]
pub fn digest(key: &[u8]) -> [u8; 20] {
    let mut ctx = digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY);
    ctx.update(key);
    ctx.update(GUID.as_bytes());
    ctx.finish().as_ref().try_into().unwrap()
}

/// Calculate the SHA-1 digest of a WebSocket key and the GUID using the
/// [`aws-lc-rs`] crate.
#[cfg(all(feature = "aws_lc_rs", not(feature = "openssl")))]
pub fn digest(key: &[u8]) -> [u8; 20] {
    let mut ctx = digest::Context::new(&digest::SHA1_FOR_LEGACY_USE_ONLY);
    ctx.update(key);
    ctx.update(GUID.as_bytes());
    ctx.finish().as_ref().try_into().unwrap()
}

/// Calculate the SHA-1 digest of a WebSocket key and the GUID using the
/// [`openssl`] crate.
#[cfg(feature = "openssl")]
pub fn digest(key: &[u8]) -> [u8; 20] {
    let mut hasher = Sha1::new();
    hasher.update(key);
    hasher.update(GUID.as_bytes());
    hasher.finish()
}
