//! [`Secret`] wrapper type for more carefully handling secret values
//! (e.g. passwords, cryptographic keys, access tokens or other credentials)
//!
//! # Goals
//!
//! - Make secret access explicit and easy-to-audit via the
//!   [`ExposeSecret`] trait. This also makes secret values immutable which
//!   helps avoid making accidental copies (e.g. reallocating the backing
//!   buffer for a `Vec`)
//! - Prevent accidental leakage of secrets via channels like debug logging
//! - Ensure secrets are wiped from memory on drop securely
//!   (using the [`zeroize`] crate)
//!
//! Presently this crate favors a simple, `no_std`-friendly, safe i.e.
//! `forbid(unsafe_code)`-based implementation and does not provide more advanced
//! memory protection mechanisms e.g. ones based on `mlock(2)`/`mprotect(2)`.
//! We may explore more advanced protection mechanisms in the future.
//!
//! # `Box`, `String`, and `Vec` wrappers
//!
//! Most users of this crate will simply want [`Secret`] wrappers around Rust's
//! core collection types: i.e. `Box`, `String`, and `Vec`.
//!
//! When the `alloc` feature of this crate is enabled (which it is by default),
//! [`SecretBox`], [`SecretString`], and [`SecretVec`] type aliases are
//! available.
//!
//! There's nothing particularly fancy about these: they're just the simple
//! composition of `Secret<Box<_>>`, `Secret<String>`, and `Secret<Vec<_>>`!
//! However, in many cases they're all you will need.
//!
//! # Advanced usage
//!
//! If you are hitting limitations on what's possible with the collection type
//! wrappers, you'll want to define your own newtype which lets you customize
//! the implementation:
//!
//! ```rust
//! use secrecy::{CloneableSecret, DebugSecret, Secret, Zeroize};
//!
//! #[derive(Clone)]
//! pub struct AccountNumber(String);
//!
//! impl Zeroize for AccountNumber {
//!     fn zeroize(&mut self) {
//!         self.0.zeroize();
//!     }
//! }
//!
//! /// Permits cloning
//! impl CloneableSecret for AccountNumber {}
//!
//! /// Provides a `Debug` impl (by default `[[REDACTED]]`)
//! impl DebugSecret for AccountNumber {}
//!
//! /// Use this alias when storing secret values
//! pub type SecretAccountNumber = Secret<AccountNumber>;
//! ```
//!
//! # `serde` support
//!
//! When the `serde` feature of this crate is enabled, the [`Secret`] type will
//! receive a [`Deserialize`] impl for all `Secret<T>` types where
//! `T: DeserializeOwned`. This allows *loading* secret values from data
//! deserialized from `serde` (be careful to clean up any intermediate secrets
//! when doing this, e.g. the unparsed input!)
//!
//! To prevent exfiltration of secret values via `serde`, by default `Secret<T>`
//! does *not* receive a corresponding [`Serialize`] impl. If you would like
//! types of `Secret<T>` to be serializable with `serde`, you will need to impl
//! the [`SerializableSecret`] marker trait on `T`.

#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc(html_root_url = "https://docs.rs/secrecy/0.8.0")]
#![forbid(unsafe_code)]
#![warn(missing_docs, rust_2018_idioms, unused_qualifications)]

#[cfg(feature = "alloc")]
extern crate alloc;

#[cfg(feature = "alloc")]
mod boxed;
#[cfg(feature = "bytes")]
mod bytes;
#[cfg(feature = "alloc")]
mod string;
#[cfg(feature = "alloc")]
mod vec;

pub use zeroize::{self, Zeroize};

#[cfg(feature = "alloc")]
pub use self::{boxed::SecretBox, string::SecretString, vec::SecretVec};

#[cfg(feature = "bytes")]
pub use self::bytes::SecretBytesMut;

use core::{
    any,
    fmt::{self, Debug},
};

#[cfg(feature = "serde")]
use serde::{de, ser, Deserialize, Serialize};

/// Wrapper type for values that contains secrets, which attempts to limit
/// accidental exposure and ensure secrets are wiped from memory when dropped.
/// (e.g. passwords, cryptographic keys, access tokens or other credentials)
///
/// Access to the secret inner value occurs through the [`ExposeSecret`] trait,
/// which provides an `expose_secret()` method for accessing the inner secret
/// value.
pub struct Secret<S>
where
    S: Zeroize,
{
    /// Inner secret value
    inner_secret: S,
}

impl<S> Secret<S>
where
    S: Zeroize,
{
    /// Take ownership of a secret value
    pub fn new(secret: S) -> Self {
        Secret {
            inner_secret: secret,
        }
    }
}

impl<S> ExposeSecret<S> for Secret<S>
where
    S: Zeroize,
{
    fn expose_secret(&self) -> &S {
        &self.inner_secret
    }
}

impl<S> From<S> for Secret<S>
where
    S: Zeroize,
{
    fn from(secret: S) -> Self {
        Self::new(secret)
    }
}

impl<S> Clone for Secret<S>
where
    S: CloneableSecret,
{
    fn clone(&self) -> Self {
        Secret {
            inner_secret: self.inner_secret.clone(),
        }
    }
}

impl<S> Debug for Secret<S>
where
    S: Zeroize + DebugSecret,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(")?;
        S::debug_secret(f)?;
        f.write_str(")")
    }
}

impl<S> Drop for Secret<S>
where
    S: Zeroize,
{
    fn drop(&mut self) {
        // Zero the secret out from memory
        self.inner_secret.zeroize();
    }
}

/// Marker trait for secrets which are allowed to be cloned
pub trait CloneableSecret: Clone + Zeroize {}

/// Implement `CloneableSecret` on arrays of types that impl `Clone` and
/// `Zeroize`.
macro_rules! impl_cloneable_secret_for_array {
    ($($size:expr),+) => {
        $(
            impl<T: Clone + Zeroize> CloneableSecret for [T; $size] {}
        )+
     };
}

// TODO(tarcieri): const generics
impl_cloneable_secret_for_array!(
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
    51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64
);

/// Expose a reference to an inner secret
pub trait ExposeSecret<S> {
    /// Expose secret: this is the only method providing access to a secret.
    fn expose_secret(&self) -> &S;
}

/// Debugging trait which is specialized for handling secret values
pub trait DebugSecret {
    /// Format information about the secret's type.
    ///
    /// This can be thought of as an equivalent to [`Debug::fmt`], but one
    /// which by design does not permit access to the secret value.
    fn debug_secret(f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        f.write_str("[REDACTED ")?;
        f.write_str(any::type_name::<Self>())?;
        f.write_str("]")
    }
}

/// Implement `DebugSecret` on arrays of types that impl `Debug`.
macro_rules! impl_debug_secret_for_array {
    ($($size:expr),+) => {
        $(
            impl<T: Debug> DebugSecret for [T; $size] {}
        )+
     };
}

// TODO(tarcieri): const generics
impl_debug_secret_for_array!(
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
    51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64
);

/// Marker trait for secret types which can be [`Serialize`]-d by [`serde`].
///
/// When the `serde` feature of this crate is enabled and types are marked with
/// this trait, they receive a [`Serialize` impl][1] for `Secret<T>`.
/// (NOTE: all types which impl `DeserializeOwned` receive a [`Deserialize`]
/// impl)
///
/// This is done deliberately to prevent accidental exfiltration of secrets
/// via `serde` serialization.
///
/// If you are working with [`SecretString`] or [`SecretVec`], not that
/// by design these types do *NOT* impl this trait.
///
/// If you really want to have `serde` serialize those types, use the
/// [`serialize_with`][2] attribute to specify a serializer that exposes the secret.
///
/// [1]: https://docs.rs/secrecy/latest/secrecy/struct.Secret.html#implementations
/// [2]: https://serde.rs/field-attrs.html#serialize_with
#[cfg(feature = "serde")]
#[cfg_attr(docsrs, doc(cfg(feature = "serde")))]
pub trait SerializableSecret: Serialize {}

#[cfg(feature = "serde")]
impl<'de, T> Deserialize<'de> for Secret<T>
where
    T: Zeroize + Clone + de::DeserializeOwned + Sized,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        T::deserialize(deserializer).map(Secret::new)
    }
}

#[cfg(feature = "serde")]
impl<T> Serialize for Secret<T>
where
    T: Zeroize + SerializableSecret + Serialize + Sized,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        self.expose_secret().serialize(serializer)
    }
}
