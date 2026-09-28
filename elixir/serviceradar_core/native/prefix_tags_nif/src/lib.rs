// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

//! Packed prefix-tag snapshot core. Database access and publication belong to
//! Elixir; this crate only owns native entries and longest-prefix lookup.

#[cfg(feature = "nif")]
mod native;

mod entry;
mod prefix;
mod trie;

pub use entry::{Entry, Indicator};
pub use prefix::Prefix;
pub use trie::{Stats, Trie};

#[cfg(test)]
mod tests;

#[cfg(feature = "nif")]
rustler::init!("Elixir.ServiceRadar.PrefixTags.Native");
