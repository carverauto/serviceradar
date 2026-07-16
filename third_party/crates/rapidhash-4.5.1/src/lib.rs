#![cfg_attr(docsrs, doc = include_str!("../README.md"))]
#![cfg_attr(not(docsrs), doc = "# Rapidhash")]

#![cfg_attr(docsrs, feature(doc_cfg))]
#![cfg_attr(docsrs, doc(auto_cfg(hide(docsrs))))]

#![cfg_attr(not(feature = "std"), no_std)]
#![cfg_attr(feature = "nightly", feature(likely_unlikely))]
#![cfg_attr(feature = "nightly", feature(hasher_prefixfree_extras))]

#![deny(missing_docs)]
#![deny(unused_must_use)]
#![allow(clippy::manual_hash_one)]

pub(crate) mod util;

pub mod v1;
pub mod v2;
pub mod v3;

pub mod inner;
pub mod fast;
pub mod quality;
#[cfg(any(feature = "std", docsrs))]
mod collections;

pub mod rng;

#[doc(inline)]
#[cfg(any(feature = "std", docsrs))]
pub use collections::*;
