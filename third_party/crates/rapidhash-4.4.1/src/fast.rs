//! In-memory hashing: RapidHasher with a focus on speed.
//!
//! Designed to maximize hashmap fetch and insert performance on most datasets.
//!
//! This is a specific instantiation of the [`crate::inner`] module with the following settings:
//! - `AVALANCHE` is disabled.
//! - `SPONGE` is enabled.
//! - `COMPACT` is disabled, unless building for WASM targets.
//! - `PROTECTED` is disabled.

const AVALANCHE: bool = false;
const SPONGE: bool = true;
const COMPACT: bool = cfg!(target_family = "wasm");
const PROTECTED: bool = false;

use crate::inner;

/// A [`std::hash::Hasher`] inspired by [`crate::v3::rapidhash_v3`] with a focus on speed and
/// throughput.
///
/// This is an alias for [inner::RapidHasher] with the following settings:
/// - `AVALANCHE` is disabled.
/// - `SPONGE` is enabled.
/// - `COMPACT` is disabled.
/// - `PROTECTED` is disabled.
///
/// Use [`crate::quality::RapidHasher`] for a higher quality hash output where necessary.
pub type RapidHasher<'s> = inner::RapidHasher<'s, AVALANCHE, SPONGE, COMPACT, PROTECTED>;

/// A rapidhash equivalent to [`std::hash::RandomState`] that uses a random seed and secrets for
/// minimal DoS resistance.
///
/// This initializes a [`crate::quality::RapidHasher`] with the following settings:
/// - `AVALANCHE` is disabled.
/// - `SPONGE` is enabled.
/// - `COMPACT` is disabled.
/// - `PROTECTED` is disabled.
///
/// Use [crate::quality::RandomState] for a higher quality but slower hash output where desirable.
pub type RandomState = inner::RandomState<AVALANCHE, SPONGE, COMPACT, PROTECTED>;

/// A [`std::hash::BuildHasher`] that uses user-provided seed and secrets.
///
/// We recommend using [`RandomState`] or [`GlobalState`] instead for most use cases.
///
/// This initializes a [`RapidHasher`] with the following settings:
/// - `AVALANCHE` is disabled.
/// - `SPONGE` is enabled.
/// - `COMPACT` is disabled.
/// - `PROTECTED` is disabled.
///
/// Use [`crate::quality::SeedableState`] for a higher quality but slower hash output where desirable.
pub type SeedableState<'secrets> = inner::SeedableState<'secrets, AVALANCHE, SPONGE, COMPACT, PROTECTED>;

/// A [`std::hash::BuildHasher`] that uses a global seed and secrets, randomized only once on startup.
///
/// All instances of GlobalState will use the same global seed and secrets for the lifetime of the
/// program. This provides minimal HashDoS resistance by randomizing the seed and secrets between
/// application runs.
///
/// This initializes a [`RapidHasher`] with the following settings:
/// - `AVALANCHE` is disabled.
/// - `SPONGE` is enabled.
/// - `COMPACT` is disabled.
/// - `PROTECTED` is disabled.
///
/// Use [`crate::quality::GlobalState`] for a higher quality but slower hash output where desirable.
pub type GlobalState = inner::GlobalState<AVALANCHE, SPONGE, COMPACT, PROTECTED>;

#[cfg(any(feature = "std", docsrs))]
#[deprecated(since = "0.4.0", note = "Please use the top-level rapidhash::RapidHashMap instead")]
pub use crate::RapidHashMap;

#[cfg(any(feature = "std", docsrs))]
#[deprecated(since = "0.4.0", note = "Please use the top-level rapidhash::RapidHashSet instead")]
pub use crate::RapidHashSet;

#[cfg(any(feature = "std", docsrs))]
#[deprecated(since = "0.4.0", note = "Please use the top-level rapidhash::HashMapExt instead")]
pub use crate::HashMapExt;

#[cfg(any(feature = "std", docsrs))]
#[deprecated(since = "0.4.0", note = "Please use the top-level rapidhash::HashSetExt instead")]
pub use crate::HashSetExt;
