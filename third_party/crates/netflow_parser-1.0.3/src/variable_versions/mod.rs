//! Variable-length NetFlow protocols (V9 and IPFIX).
//!
//! This module provides parsers and data structures for NetFlow V9 and IPFIX protocols,
//! which use template-based field definitions for flexible flow record formats.
//!
//! # Architecture
//!
//! NetFlow V9 and IPFIX are template-based protocols where:
//! 1. **Templates** define the structure of data records (field types and lengths)
//! 2. **Data Records** contain the actual flow information
//! 3. **Templates are cached** and reused across multiple data records
//!
//! ## Key Differences: V9 vs IPFIX
//!
//! | Feature | NetFlow V9 | IPFIX |
//! |---------|-----------|-------|
//! | Standard | Cisco proprietary | IETF standard (RFC 7011) |
//! | Template IDs | 256-65535 | 256-65535 |
//! | Enterprise Fields | Limited support | Full enterprise field support |
//! | Variable Length | Fixed length only | Variable length fields supported |
//!
//! # Template Caching
//!
//! Both V9 and IPFIX parsers maintain an LRU cache of templates to avoid
//! reprocessing template definitions. Configure cache size via [`Config`]:
//!
//! ```
//! use netflow_parser::variable_versions::Config;
//!
//! let config = Config::new(10000, None);
//! ```
//!
//! # Enterprise Fields
//!
//! IPFIX supports vendor-specific fields through enterprise IDs. Common vendors:
//!
//! | Vendor | Enterprise ID | Module |
//! |--------|---------------|--------|
//! | IANA (standard) | 0 | [`ipfix::lookup::IANAIPFixField`] |
//! | Cisco | 9 | [`ipfix::lookup::CiscoIPFixField`] |
//! | NetScaler | 5951 | [`ipfix::lookup::NetscalerIPFixField`] |
//! | YAF | 6871 | [`ipfix::lookup::YafIPFixField`] |
//! | VMware | 6876 | [`ipfix::lookup::VMWareIPFixField`] |
//!
//! Register custom enterprise fields using [`enterprise_registry::EnterpriseFieldRegistry`]:
//!
//! ```
//! use netflow_parser::variable_versions::enterprise_registry::EnterpriseFieldRegistry;
//!
//! let mut registry = EnterpriseFieldRegistry::new();
//! // Register your custom fields...
//! ```
//!
//! # TTL (Template Expiration)
//!
//! Templates can be configured to expire after a certain time using [`TtlConfig`].
//! This is useful for long-running parsers to avoid stale template issues.
//!
//! # Modules
//!
//! - [`v9`] - NetFlow V9 parser and data structures
//! - [`ipfix`] - IPFIX parser and data structures
//! - [`v9::lookup`] - V9 field type definitions
//! - [`ipfix::lookup`] - IPFIX field type definitions (IANA and enterprise)
//! - [`field_value`] - Field value types and parsing
//! - [`enterprise_registry`] - Custom enterprise field registration
//! - [`ttl`] - Template expiration configuration
//! - [`metrics`] - Template cache performance metrics

pub(crate) mod config;
pub mod enterprise_registry;
pub(crate) mod fast_parse;
pub mod field_types;
pub mod field_value;
pub mod ipfix;
pub mod metrics;
pub(crate) mod pending_flows;
pub mod template_events;
pub mod ttl;
pub mod v9;

// Re-export public types to preserve existing import paths
pub use config::ParserConfig;
pub(crate) use config::ParserFields;
pub use config::{
    Config, ConfigError, DEFAULT_MAX_RECORDS_PER_FLOWSET, DEFAULT_MAX_TEMPLATE_CACHE_SIZE,
    MAX_FIELD_COUNT,
};
pub use pending_flows::PendingFlowsConfig;

// Re-export crate-internal types for use by sibling modules
pub(crate) use config::TemplateId;
pub(crate) use pending_flows::{PendingFlowCache, PendingFlowEntry};

use crate::variable_versions::metrics::CacheMetricsInner;
use crate::variable_versions::ttl::TtlConfig;

/// Information about a data flowset that couldn't be parsed due to missing template.
/// This provides context to help diagnose template-related issues.
#[non_exhaustive]
#[derive(Debug, Clone, serde::Serialize)]
pub struct NoTemplateInfo {
    /// The template ID that was requested but not found
    pub template_id: u16,
    /// The unparsed flowset data (for potential retry after template arrives)
    pub raw_data: Vec<u8>,
    /// Whether the raw_data was truncated due to size limits
    pub truncated: bool,
}

impl NoTemplateInfo {
    /// Create a new NoTemplateInfo with the given template ID and raw data
    pub fn new(template_id: u16, raw_data: Vec<u8>) -> Self {
        Self {
            template_id,
            raw_data,
            truncated: false,
        }
    }
}

impl PartialEq for NoTemplateInfo {
    fn eq(&self, other: &Self) -> bool {
        self.template_id == other.template_id
            && self.raw_data == other.raw_data
            && self.truncated == other.truncated
    }
}

impl Eq for NoTemplateInfo {}

/// Calculate padding needed to align `body_size` to a 4-byte boundary.
/// `body_size` should be the flowset body length *excluding* the 4-byte set header
/// (since the header is already aligned, `(header + body) % 4 == body % 4`).
/// Returns a static slice of zero bytes with the appropriate length (0-3).
pub(crate) fn calculate_padding(body_size: usize) -> &'static [u8] {
    const PADDING: [u8; 3] = [0u8; 3];
    const PADDING_SIZES: [usize; 4] = [0, 3, 2, 1];
    let padding_len = PADDING_SIZES[body_size % 4];
    &PADDING[..padding_len]
}

/// Helper to get a valid template from an LRU cache, checking TTL if configured.
/// Returns None if the template doesn't exist or has expired.
#[inline]
pub(crate) fn get_valid_template<T: Clone>(
    cache: &mut lru::LruCache<TemplateId, ttl::TemplateWithTtl<std::sync::Arc<T>>>,
    id: &TemplateId,
    ttl_config: &Option<TtlConfig>,
    metrics: &mut CacheMetricsInner,
) -> Option<std::sync::Arc<T>> {
    if let Some(wrapped) = cache.peek(id) {
        if let Some(config) = ttl_config
            && wrapped.is_expired(config)
        {
            cache.pop(id);
            metrics.record_expiration();
            return None;
        }
        // Hit is recorded by the caller at the flowset level, not per-cache-probe
        // Promote to most-recently-used only after confirming non-expired
        let template = std::sync::Arc::clone(&wrapped.template);
        cache.promote(id);
        return Some(template);
    }
    None
}

/// Like `get_valid_template` but does NOT promote the entry in the LRU.
/// Used in replay paths where the parse may fail — promotion should only
/// happen on a successful replay (callers promote manually on success).
pub(crate) fn peek_valid_template<T: Clone>(
    cache: &mut lru::LruCache<TemplateId, ttl::TemplateWithTtl<std::sync::Arc<T>>>,
    id: &TemplateId,
    ttl_config: &Option<TtlConfig>,
    metrics: &mut CacheMetricsInner,
) -> Option<std::sync::Arc<T>> {
    if let Some(wrapped) = cache.peek(id) {
        if let Some(config) = ttl_config
            && wrapped.is_expired(config)
        {
            cache.pop(id);
            metrics.record_expiration();
            return None;
        }
        return Some(std::sync::Arc::clone(&wrapped.template));
    }
    None
}
