#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg, doc_auto_cfg))]
#![doc = include_str!("../README.md")]
#![deny(unsafe_code)]
#![warn(
    clippy::mod_module_files,
    missing_docs,
    missing_debug_implementations,
    missing_copy_implementations,
    rust_2018_idioms,
    trivial_casts,
    trivial_numeric_casts,
    unused_qualifications,
    clippy::unwrap_used
)]

extern crate alloc;

mod error;
pub mod fips;
mod generic;
pub mod hazmat;
mod presets;

#[cfg(feature = "multicore")]
pub mod multicore;

pub use error::Error;
pub use generic::sieve_and_find;
pub use presets::{Flavor, is_prime, random_prime};
