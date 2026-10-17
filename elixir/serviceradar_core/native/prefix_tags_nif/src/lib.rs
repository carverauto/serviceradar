// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

//! Packed prefix-tag snapshot core. Database access and publication belong to
//! Elixir; this crate owns native entries, prefix-chain lookup and bounded
//! label discovery/range selection over the same immutable snapshots.

#[cfg(feature = "nif")]
mod native;

mod catalog;
mod entry;
mod prefix;
mod trie;

pub use catalog::{Catalog, LabelPage};
pub use entry::{Entry, Indicator};
pub use prefix::Prefix;
pub use trie::{Stats, Trie};

#[cfg(test)]
mod tests;

#[cfg(feature = "nif")]
rustler::init!("Elixir.ServiceRadar.PrefixTags.Native");
