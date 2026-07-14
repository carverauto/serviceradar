#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/iqlusioninc/crates/main/signatory/img/signatory-rustacean.svg"
)]
#![forbid(unsafe_code)]
#![warn(
    clippy::unwrap_used,
    missing_docs,
    rust_2018_idioms,
    unused_qualifications
)]

extern crate alloc;

#[cfg(feature = "std")]
extern crate std;

#[cfg(feature = "ecdsa")]
pub mod ecdsa;

#[cfg(feature = "ed25519")]
pub mod ed25519;

mod algorithm;
mod error;
mod key;

pub use self::{
    algorithm::Algorithm,
    error::{Error, Result},
    key::{
        handle::KeyHandle,
        info::KeyInfo,
        name::KeyName,
        ring::{KeyRing, LoadPkcs8},
        store::GeneratePkcs8,
    },
};
pub use pkcs8;
pub use signature;

#[cfg(feature = "std")]
pub use key::store::fs::FsKeyStore;

/// Map type.
pub type Map<K, V> = alloc::collections::BTreeMap<K, V>;
