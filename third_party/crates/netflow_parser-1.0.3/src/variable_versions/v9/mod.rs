//! # NetFlow V9
//!
//! Types and parsing logic for Cisco NetFlow Version 9 (RFC 3954).
//!
//! Key types:
//! - [`V9`] — a parsed V9 packet containing a [`Header`] and a list of [`FlowSet`]s
//! - [`V9Parser`] — stateful parser with an LRU template cache
//! - [`Template`] / [`OptionsTemplate`] — template definitions that describe data record layout
//! - [`Data`] / [`OptionsData`] — parsed data records decoded using a cached template
//! - [`FlowSetBody`] — enum of all possible flowset payloads (templates, data, options, or no-template)
//!
//! Module layout:
//! - `types` — struct/enum definitions with nom-derived parsing
//! - `parser` — stateful `V9Parser` and manual parse impl blocks
//! - `serializer` — binary serialization (`to_be_bytes`)
//! - `lookup` — field type lookups
//!
//! References:
//! - <https://www.ietf.org/rfc/rfc3954.txt>
//! - <https://www.cisco.com/en/US/technologies/tk648/tk362/technologies_white_paper09186a00800a3db9.html>

pub mod lookup;
pub(crate) mod parser;
mod serializer;
mod types;

// Re-export all public types from types.rs
pub use types::*;

// Re-export the stateful parser
pub use parser::V9Parser;

// Re-export parent items that parser.rs and serializer.rs need via `super::`
pub(crate) use super::{
    DEFAULT_MAX_TEMPLATE_CACHE_SIZE, MAX_FIELD_COUNT, TemplateId, calculate_padding,
};
