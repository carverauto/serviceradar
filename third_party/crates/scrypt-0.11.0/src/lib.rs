//! This crate implements the Scrypt key derivation function as specified
//! in \[1\].
//!
//! If you are only using the low-level [`scrypt`] function instead of the
//! higher-level [`Scrypt`] struct to produce/verify hash strings,
//! it's recommended to disable default features in your `Cargo.toml`:
//!
//! ```toml
//! [dependencies]
//! scrypt = { version = "0.2", default-features = false }
//! ```
//!
//! # Usage (simple with default params)
//!
//! ```
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! # #[cfg(all(feature = "simple", feature = "std"))]
//! # {
//! use scrypt::{
//!     password_hash::{
//!         rand_core::OsRng,
//!         PasswordHash, PasswordHasher, PasswordVerifier, SaltString
//!     },
//!     Scrypt
//! };
//!
//! let password = b"hunter42"; // Bad password; don't actually use!
//! let salt = SaltString::generate(&mut OsRng);
//!
//! // Hash password to PHC string ($scrypt$...)
//! let password_hash = Scrypt.hash_password(password, &salt)?.to_string();
//!
//! // Verify password against PHC string
//! let parsed_hash = PasswordHash::new(&password_hash)?;
//! assert!(Scrypt.verify_password(password, &parsed_hash).is_ok());
//! # }
//! # Ok(())
//! # }
//! ```
//!
//! # References
//! \[1\] - [C. Percival. Stronger Key Derivation Via Sequential
//! Memory-Hard Functions](http://www.tarsnap.com/scrypt/scrypt.pdf)

#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]

#[macro_use]
extern crate alloc;
#[cfg(feature = "std")]
extern crate std;

use pbkdf2::pbkdf2_hmac;
use sha2::Sha256;

/// Errors for `scrypt` operations.
pub mod errors;
mod params;
mod romix;

#[cfg(feature = "simple")]
mod simple;

pub use crate::params::Params;

#[cfg(feature = "simple")]
pub use password_hash;

#[cfg(feature = "simple")]
pub use crate::simple::{Scrypt, ALG_ID};

/// The scrypt key derivation function.
///
/// # Arguments
/// - `password` - The password to process as a byte vector
/// - `salt` - The salt value to use as a byte vector
/// - `params` - The ScryptParams to use
/// - `output` - The resulting derived key is returned in this byte vector.
///   **WARNING: Make sure to compare this value in constant time!**
///
/// # Return
/// `Ok(())` if calculation is successful and `Err(InvalidOutputLen)` if
/// `output` does not satisfy the following condition:
/// `output.len() > 0 && output.len() <= (2^32 - 1) * 32`.
pub fn scrypt(
    password: &[u8],
    salt: &[u8],
    params: &Params,
    output: &mut [u8],
) -> Result<(), errors::InvalidOutputLen> {
    // This check required by Scrypt:
    // check output.len() > 0 && output.len() <= (2^32 - 1) * 32
    if output.is_empty() || output.len() / 32 > 0xffff_ffff {
        return Err(errors::InvalidOutputLen);
    }

    // The checks in the ScryptParams constructor guarantee
    // that the following is safe:
    let n = 1 << params.log_n;
    let r128 = (params.r as usize) * 128;
    let pr128 = (params.p as usize) * r128;
    let nr128 = n * r128;

    let mut b = vec![0u8; pr128];
    pbkdf2_hmac::<Sha256>(password, salt, 1, &mut b);

    let mut v = vec![0u8; nr128];
    let mut t = vec![0u8; r128];

    for chunk in &mut b.chunks_mut(r128) {
        romix::scrypt_ro_mix(chunk, &mut v, &mut t, n);
    }

    pbkdf2_hmac::<Sha256>(password, &b, 1, output);
    Ok(())
}
