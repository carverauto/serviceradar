//! Traits for working with Errors.
//!
//! # Usage
//!
//! If you're a library, you should reexport *all the features* exposed by this
//! crate.

// If std feature is disabled, this crate is no_std.
// This avoids making this crate fail on std build in version 1.5.0 and under
#![cfg_attr(not(feature = "std"), no_std)]

#[cfg(feature = "std")]
pub use std::error::*;

#[cfg(not(feature = "std"))]
mod error_trait;

#[cfg(not(feature = "std"))]
pub use error_trait::*;