//! # IPFIX (IP Flow Information Export)
//!
//! Types and parsing logic for IPFIX (RFC 7011), the IETF standard evolution of NetFlow V9.
//!
//! IPFIX extends V9 with variable-length fields, enterprise-specific information elements,
//! and a length-based message header (instead of V9's count-based header).
//!
//! Key types:
//! - [`IPFix`] — a parsed IPFIX message containing a [`Header`] and a list of [`FlowSet`]s
//! - [`IPFixParser`] — stateful parser with LRU template caches (supports both IPFIX and V9-style templates)
//! - [`Template`] / [`OptionsTemplate`] — IPFIX template definitions with enterprise field support
//! - [`Data`] / [`OptionsData`] — parsed data records decoded using a cached template
//! - [`FlowSetBody`] — enum of all possible flowset payloads
//!
//! Module layout:
//! - `types` — struct/enum/trait definitions with nom-derived parsing
//! - `parser` — stateful `IPFixParser` impl blocks and manual parse logic
//! - `serializer` — binary serialization (`to_be_bytes`)
//! - `lookup` — field type lookups
//!
//! References:
//! - <https://datatracker.ietf.org/doc/html/rfc7011>
//! - <https://en.wikipedia.org/wiki/IP_Flow_Information_Export>
//! - <https://www.ibm.com/docs/en/npi/1.3.1?topic=overview-ipfix-message-format>
//! - <https://www.iana.org/assignments/ipfix/ipfix.xhtml>

pub mod lookup;
mod parser;
mod serializer;
mod types;

// Re-export all public types from types.rs
pub use types::*;

// Re-export parent items that parser.rs and serializer.rs need via `super::`
pub(crate) use super::{DEFAULT_MAX_TEMPLATE_CACHE_SIZE, MAX_FIELD_COUNT, calculate_padding};
