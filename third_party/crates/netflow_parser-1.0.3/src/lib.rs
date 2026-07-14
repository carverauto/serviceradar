#![forbid(unsafe_code)]
#![doc = include_str!("../README.md")]

#[cfg(feature = "netflow_common")]
pub mod netflow_common;
pub mod protocol;
pub mod scoped_parser;
pub mod static_versions;
pub mod template_store;
mod tests;
pub mod variable_versions;

#[cfg(feature = "netflow_common")]
use crate::netflow_common::{NetflowCommon, NetflowCommonError, NetflowCommonFlowSet};

use static_versions::{
    v5::{V5, V5Parser},
    v7::{V7, V7Parser},
};
use variable_versions::ParserConfig;
use variable_versions::ipfix::{IPFix, IPFixParser};
use variable_versions::v9::{V9, V9Parser};

use nom_derive::{Nom, Parse};
use serde::Serialize;
use std::sync::Arc;

/// Count non-expired templates in an LRU cache, respecting TTL if configured.
fn count_valid_templates<T>(
    cache: &lru::LruCache<u16, variable_versions::ttl::TemplateWithTtl<T>>,
    ttl_config: &Option<variable_versions::ttl::TtlConfig>,
) -> usize {
    match ttl_config {
        Some(cfg) => cache.iter().filter(|(_, t)| !t.is_expired(cfg)).count(),
        None => cache.len(),
    }
}

// Re-export scoped parser types for convenience
pub use scoped_parser::{
    AutoScopedParser, DEFAULT_MAX_SOURCES, IpfixSourceKey, RouterScopedParser, ScopingInfo,
    V9SourceKey, extract_scoping_info,
};

// Re-export template event types for convenience
pub use variable_versions::template_events::{
    TemplateEvent, TemplateHook, TemplateHookError, TemplateHooks, TemplateProtocol,
};

// Re-export configuration and utility types for convenience
pub use template_store::{
    InMemoryTemplateStore, TemplateKind, TemplateStore, TemplateStoreError, TemplateStoreKey,
};
pub use variable_versions::enterprise_registry::{EnterpriseFieldDef, EnterpriseFieldRegistry};
pub use variable_versions::metrics::{CacheInfo, CacheMetrics, ParserCacheInfo};
pub use variable_versions::ttl::TtlConfig;
pub use variable_versions::{
    Config, ConfigError, DEFAULT_MAX_RECORDS_PER_FLOWSET, NoTemplateInfo, PendingFlowsConfig,
};

// Rust-idiomatic naming aliases
pub use variable_versions::ipfix::lookup::IpfixField;
pub use variable_versions::ipfix::{Ipfix, IpfixFieldPair, IpfixFlowRecord, IpfixParser};

// Re-export commonly used field/data types
pub use variable_versions::field_value::{DataNumber, FieldDataType, FieldValue};
pub use variable_versions::v9::lookup::V9Field;
pub use variable_versions::v9::{V9FieldPair, V9FlowRecord};

/// Enum of supported Netflow Versions
#[non_exhaustive]
#[derive(Debug, PartialEq, Clone, Serialize)]
pub enum NetflowPacket {
    /// Version 5
    V5(V5),
    /// Version 7
    V7(V7),
    /// Version 9
    V9(V9),
    /// IPFix
    IPFix(IPFix),
}

impl NetflowPacket {
    /// Returns `true` if this is a NetFlow V5 packet.
    pub fn is_v5(&self) -> bool {
        matches!(self, Self::V5(_v))
    }
    /// Returns `true` if this is a NetFlow V7 packet.
    pub fn is_v7(&self) -> bool {
        matches!(self, Self::V7(_v))
    }
    /// Returns `true` if this is a NetFlow V9 packet.
    pub fn is_v9(&self) -> bool {
        matches!(self, Self::V9(_v))
    }
    /// Returns `true` if this is an IPFIX packet.
    pub fn is_ipfix(&self) -> bool {
        matches!(self, Self::IPFix(_v))
    }
    #[cfg(feature = "netflow_common")]
    pub fn as_netflow_common(&self) -> Result<NetflowCommon, NetflowCommonError> {
        self.try_into()
    }
}

/// Result of parsing NetFlow packets from a byte buffer.
///
/// This struct contains both successfully parsed packets and an optional error
/// that stopped parsing. This ensures no data loss when parsing fails partway
/// through a buffer.
///
/// # Examples
///
/// ```rust
/// use netflow_parser::NetflowParser;
///
/// let mut parser = NetflowParser::default();
/// let buffer = vec![/* netflow data */];
///
/// let result = parser.parse_bytes(&buffer);
///
/// // Process all successfully parsed packets
/// for packet in result.packets {
///     println!("Parsed packet");
/// }
///
/// // Check if parsing stopped due to error
/// if let Some(error) = result.error {
///     eprintln!("Parsing stopped: {}", error);
/// }
/// ```
#[non_exhaustive]
#[derive(Debug, Clone, Serialize)]
#[must_use = "parsing results should not be discarded; check .packets and .error"]
pub struct ParseResult {
    /// Successfully parsed NetFlow packets.
    /// This vec contains all packets that were successfully parsed before
    /// any error occurred.
    pub packets: Vec<NetflowPacket>,

    /// Optional error that stopped parsing.
    /// - `None` means all data was successfully parsed
    /// - `Some(error)` means parsing stopped due to an error, but `packets`
    ///   contains all successfully parsed packets up to that point
    pub error: Option<NetflowError>,
}

impl ParseResult {
    /// Returns true if parsing completed without errors.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let mut parser = NetflowParser::default();
    /// let result = parser.parse_bytes(&[]);
    /// assert!(result.is_ok());
    /// ```
    pub fn is_ok(&self) -> bool {
        self.error.is_none()
    }

    /// Returns true if parsing stopped due to an error.
    ///
    /// Note: Even when this returns `true`, `packets` may contain
    /// successfully parsed packets.
    pub fn is_err(&self) -> bool {
        self.error.is_some()
    }
}

#[derive(Nom)]
/// Generic Netflow Header for shared versions
struct GenericNetflowHeader {
    version: u16,
}

/// Main parser for Netflow packets supporting V5, V7, V9, and IPFIX.
///
/// Use [`NetflowParser::builder()`] for ergonomic configuration with the builder pattern,
/// or [`NetflowParser::default()`] for quick setup with defaults.
///
/// # ⚠️ Multi-Source Deployments
///
/// **IMPORTANT**: If you're parsing NetFlow from multiple routers or sources,
/// use [`AutoScopedParser`] instead of `NetflowParser`
/// to prevent template cache collisions.
///
/// Template IDs are **NOT unique across sources**. Different routers can (and often do)
/// use the same template ID with completely different schemas. When multiple sources
/// share a single `NetflowParser`, their templates collide in the cache, causing:
///
/// - Template thrashing (constant eviction and re-learning)
/// - Parsing failures (data parsed with wrong template)
/// - Performance degradation (high cache miss rate)
///
/// ## Single Source (✅ Use NetflowParser)
///
/// ```rust
/// use netflow_parser::NetflowParser;
///
/// let mut parser = NetflowParser::default();
/// let data = [0u8; 72]; // Example NetFlow data
/// // Single router/source - no collisions possible
/// let packets = parser.parse_bytes(&data);
/// ```
///
/// ## Multiple Sources (✅ Use AutoScopedParser)
///
/// ```rust
/// use netflow_parser::AutoScopedParser;
/// use std::net::SocketAddr;
///
/// let mut parser = AutoScopedParser::new();
/// let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();
/// let data = [0u8; 72]; // Example NetFlow data
/// // Each source gets isolated template cache (RFC-compliant)
/// let packets = parser.parse_from_source(source, &data);
/// ```
///
/// # Examples
///
/// ```rust
/// use netflow_parser::NetflowParser;
/// use netflow_parser::variable_versions::ttl::TtlConfig;
/// use std::time::Duration;
///
/// // Using builder pattern (recommended)
/// let parser = NetflowParser::builder()
///     .with_cache_size(2000)
///     .with_ttl(TtlConfig::new(Duration::from_secs(7200)))
///     .build()
///     .expect("Failed to build parser");
///
/// // Using default
/// let parser = NetflowParser::default();
/// ```
#[derive(Debug)]
pub struct NetflowParser {
    pub(crate) v9_parser: V9Parser,
    pub(crate) ipfix_parser: IPFixParser,
    /// Which NetFlow versions are accepted for parsing.
    /// Indexed by version number (e.g., index 5 = V5, index 9 = V9, index 10 = IPFIX).
    /// `true` means the version is allowed, `false` means it will be skipped.
    pub(crate) allowed_versions: [bool; 11],
    /// Maximum number of bytes to include in error samples to prevent memory exhaustion.
    /// Defaults to 256 bytes.
    pub(crate) max_error_sample_size: usize,
    /// Template event hooks for monitoring template lifecycle events.
    template_hooks: TemplateHooks,
}

/// Builder for configuring and constructing a [`NetflowParser`].
///
/// # Examples
///
/// ```rust
/// use netflow_parser::NetflowParser;
/// use netflow_parser::variable_versions::ttl::TtlConfig;
/// use std::time::Duration;
///
/// let parser = NetflowParser::builder()
///     .with_cache_size(2000)
///     .with_ttl(TtlConfig::new(Duration::from_secs(7200)))
///     .with_allowed_versions(&[5, 9, 10])
///     .with_max_error_sample_size(512)
///     .build()
///     .expect("Failed to build parser");
/// ```
#[derive(Clone)]
pub struct NetflowParserBuilder {
    v9_config: Config,
    ipfix_config: Config,
    allowed_versions: [bool; 11],
    /// Raw version numbers passed to `with_allowed_versions`, for validation
    requested_versions: Option<Vec<u16>>,
    max_error_sample_size: usize,
    template_hooks: TemplateHooks,
    template_store: Option<Arc<dyn TemplateStore>>,
    template_store_scope: Arc<str>,
}

/// Helper to create a `[bool; 11]` allowed_versions array from a set of version numbers.
///
/// Only valid NetFlow versions (5, 7, 9, 10) are accepted; invalid version numbers
/// are recorded so that [`NetflowParserBuilder::validate`] can report them.
fn versions_to_array(versions: &[u16]) -> [bool; 11] {
    let mut arr = [false; 11];
    for &v in versions {
        // Only set entries for valid NetFlow versions; all others
        // (including 0) are caught by validate() via requested_versions.
        if matches!(v, 5 | 7 | 9 | 10) {
            arr[v as usize] = true;
        }
    }
    arr
}

// Custom Debug implementation to avoid printing closures
impl std::fmt::Debug for NetflowParserBuilder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NetflowParserBuilder")
            .field("v9_config", &self.v9_config)
            .field("ipfix_config", &self.ipfix_config)
            .field("allowed_versions", &self.allowed_versions)
            .field("max_error_sample_size", &self.max_error_sample_size)
            .field(
                "template_hooks",
                &format!("{} hooks", self.template_hooks.len()),
            )
            .field(
                "template_store",
                &if self.template_store.is_some() {
                    "configured"
                } else {
                    "none"
                },
            )
            .field("template_store_scope", &self.template_store_scope)
            .finish()
    }
}

impl Default for NetflowParserBuilder {
    fn default() -> Self {
        Self {
            v9_config: Config::new(1000, None),
            ipfix_config: Config::new(1000, None),
            allowed_versions: versions_to_array(&[5, 7, 9, 10]),
            requested_versions: None,
            max_error_sample_size: 256,
            template_hooks: TemplateHooks::new(),
            template_store: None,
            template_store_scope: Arc::from(""),
        }
    }
}

impl NetflowParserBuilder {
    /// Sets the template cache size for both V9 and IPFIX parsers.
    ///
    /// # Arguments
    ///
    /// * `size` - Maximum number of templates to cache (must be > 0)
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::builder()
    ///     .with_cache_size(2000)
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_cache_size(mut self, size: usize) -> Self {
        self.v9_config.max_template_cache_size = size;
        self.ipfix_config.max_template_cache_size = size;
        self
    }

    /// Sets the V9 parser template cache size independently.
    ///
    /// # Arguments
    ///
    /// * `size` - Maximum number of templates to cache (must be > 0)
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_v9_cache_size(mut self, size: usize) -> Self {
        self.v9_config.max_template_cache_size = size;
        self
    }

    /// Sets the IPFIX parser template cache size independently.
    ///
    /// * `size` - Maximum number of templates to cache (must be > 0)
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_ipfix_cache_size(mut self, size: usize) -> Self {
        self.ipfix_config.max_template_cache_size = size;
        self
    }

    /// Sets the maximum field count for both V9 and IPFIX parsers.
    ///
    /// This limits the number of fields allowed in a single template to prevent DoS attacks.
    ///
    /// # Arguments
    ///
    /// * `count` - Maximum number of fields per template (default: 10,000)
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::builder()
    ///     .with_max_field_count(5000)  // More restrictive limit
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_max_field_count(mut self, count: usize) -> Self {
        self.v9_config.max_field_count = count;
        self.ipfix_config.max_field_count = count;
        self
    }

    /// Sets the V9 parser maximum field count independently.
    ///
    /// # Arguments
    ///
    /// * `count` - Maximum number of fields per template
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_v9_max_field_count(mut self, count: usize) -> Self {
        self.v9_config.max_field_count = count;
        self
    }

    /// Sets the IPFIX parser maximum field count independently.
    ///
    /// # Arguments
    ///
    /// * `count` - Maximum number of fields per template
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_ipfix_max_field_count(mut self, count: usize) -> Self {
        self.ipfix_config.max_field_count = count;
        self
    }

    /// Sets the maximum total size (in bytes) of all fields in a template for both V9 and IPFIX parsers.
    ///
    /// This prevents DoS attacks via templates with excessive total field lengths. Default: u16::MAX (65535).
    ///
    /// # Arguments
    ///
    /// * `size` - Maximum total size in bytes (must be > 0)
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_max_template_total_size(mut self, size: usize) -> Self {
        self.v9_config.max_template_total_size = size;
        self.ipfix_config.max_template_total_size = size;
        self
    }

    /// Sets the V9 parser maximum template total size independently.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_v9_max_template_total_size(mut self, size: usize) -> Self {
        self.v9_config.max_template_total_size = size;
        self
    }

    /// Sets the IPFIX parser maximum template total size independently.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_ipfix_max_template_total_size(mut self, size: usize) -> Self {
        self.ipfix_config.max_template_total_size = size;
        self
    }

    /// Sets the TTL configuration for both V9 and IPFIX parsers.
    ///
    /// # Arguments
    ///
    /// * `ttl` - TTL configuration (time-based)
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    /// use netflow_parser::variable_versions::ttl::TtlConfig;
    /// use std::time::Duration;
    ///
    /// let parser = NetflowParser::builder()
    ///     .with_ttl(TtlConfig::new(Duration::from_secs(7200)))
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_ttl(mut self, ttl: variable_versions::ttl::TtlConfig) -> Self {
        self.ipfix_config.ttl_config = Some(ttl.clone());
        self.v9_config.ttl_config = Some(ttl);
        self
    }

    /// Sets the TTL configuration for V9 parser independently.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_v9_ttl(mut self, ttl: variable_versions::ttl::TtlConfig) -> Self {
        self.v9_config.ttl_config = Some(ttl);
        self
    }

    /// Sets the TTL configuration for IPFIX parser independently.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_ipfix_ttl(mut self, ttl: variable_versions::ttl::TtlConfig) -> Self {
        self.ipfix_config.ttl_config = Some(ttl);
        self
    }

    /// Sets which Netflow versions are allowed to be parsed.
    ///
    /// # Arguments
    ///
    /// * `versions` - Set of allowed version numbers (5, 7, 9, 10)
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// // Only parse V9 and IPFIX
    /// let parser = NetflowParser::builder()
    ///     .with_allowed_versions(&[9, 10])
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_allowed_versions(mut self, versions: &[u16]) -> Self {
        self.allowed_versions = versions_to_array(versions);
        self.requested_versions = Some(versions.to_vec());
        self
    }

    /// Sets the maximum error sample size for error reporting.
    ///
    /// # Arguments
    ///
    /// * `size` - Maximum bytes to include in error messages
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::builder()
    ///     .with_max_error_sample_size(512)
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_max_error_sample_size(mut self, size: usize) -> Self {
        self.max_error_sample_size = size;
        self.v9_config.max_error_sample_size = size;
        self.ipfix_config.max_error_sample_size = size;
        self
    }

    /// Sets the maximum number of data records to parse per flowset.
    ///
    /// This prevents CPU-bound DoS from maliciously large flowsets. Default: 1,024.
    ///
    /// # Arguments
    ///
    /// * `count` - Maximum number of records per flowset
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_max_records_per_flowset(mut self, count: usize) -> Self {
        self.v9_config.max_records_per_flowset = count;
        self.ipfix_config.max_records_per_flowset = count;
        self
    }

    /// Sets the V9 parser maximum records per flowset independently.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_v9_max_records_per_flowset(mut self, count: usize) -> Self {
        self.v9_config.max_records_per_flowset = count;
        self
    }

    /// Sets the IPFIX parser maximum records per flowset independently.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_ipfix_max_records_per_flowset(mut self, count: usize) -> Self {
        self.ipfix_config.max_records_per_flowset = count;
        self
    }

    /// Registers a custom enterprise field definition for both V9 and IPFIX parsers.
    ///
    /// This allows library users to define their own enterprise-specific fields without
    /// modifying the library source code. Registered fields will be parsed according to
    /// their specified data type instead of falling back to raw bytes.
    ///
    /// # Arguments
    ///
    /// * `def` - Enterprise field definition containing enterprise number, field number, name, and data type
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    /// use netflow_parser::variable_versions::enterprise_registry::EnterpriseFieldDef;
    /// use netflow_parser::variable_versions::field_value::FieldDataType;
    ///
    /// let parser = NetflowParser::builder()
    ///     .register_enterprise_field(EnterpriseFieldDef::new(
    ///         12345,  // Enterprise number
    ///         1,      // Field number
    ///         "customMetric",
    ///         FieldDataType::UnsignedDataNumber,
    ///     ))
    ///     .register_enterprise_field(EnterpriseFieldDef::new(
    ///         12345,
    ///         2,
    ///         "customApplicationName",
    ///         FieldDataType::String,
    ///     ))
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn register_enterprise_field(mut self, def: EnterpriseFieldDef) -> Self {
        // Enterprise fields are only used by the IPFIX parser; V9 does not
        // support enterprise bit fields.
        Arc::make_mut(&mut self.ipfix_config.enterprise_registry).register(def);
        self
    }

    /// Registers multiple custom enterprise field definitions at once.
    ///
    /// # Arguments
    ///
    /// * `defs` - Iterator of enterprise field definitions
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    /// use netflow_parser::variable_versions::enterprise_registry::EnterpriseFieldDef;
    /// use netflow_parser::variable_versions::field_value::FieldDataType;
    ///
    /// let fields = vec![
    ///     EnterpriseFieldDef::new(12345, 1, "field1", FieldDataType::UnsignedDataNumber),
    ///     EnterpriseFieldDef::new(12345, 2, "field2", FieldDataType::String),
    ///     EnterpriseFieldDef::new(12345, 3, "field3", FieldDataType::Ip4Addr),
    /// ];
    ///
    /// let parser = NetflowParser::builder()
    ///     .register_enterprise_fields(fields)
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn register_enterprise_fields(
        mut self,
        defs: impl IntoIterator<Item = EnterpriseFieldDef>,
    ) -> Self {
        // Enterprise fields are only used by the IPFIX parser; V9 does not
        // support enterprise bit fields.
        for def in defs.into_iter() {
            Arc::make_mut(&mut self.ipfix_config.enterprise_registry).register(def);
        }

        self
    }

    /// Enables pending flow caching for both V9 and IPFIX parsers.
    ///
    /// When enabled, flows that arrive before their template are cached.
    /// When the template later arrives, cached flows are automatically
    /// re-parsed and included in the output.
    ///
    /// # Arguments
    ///
    /// * `config` - Pending flows configuration (cache size and optional TTL)
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::{NetflowParser, PendingFlowsConfig};
    ///
    /// let parser = NetflowParser::builder()
    ///     .with_pending_flows(PendingFlowsConfig::default())
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_pending_flows(mut self, config: PendingFlowsConfig) -> Self {
        self.ipfix_config.pending_flows_config = Some(config.clone());
        self.v9_config.pending_flows_config = Some(config);
        self
    }

    /// Enables pending flow caching for the V9 parser only.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_v9_pending_flows(mut self, config: PendingFlowsConfig) -> Self {
        self.v9_config.pending_flows_config = Some(config);
        self
    }

    /// Enables pending flow caching for the IPFIX parser only.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_ipfix_pending_flows(mut self, config: PendingFlowsConfig) -> Self {
        self.ipfix_config.pending_flows_config = Some(config);
        self
    }

    /// Hint for single-source deployments (documentation only).
    ///
    /// This method exists for clarity and returns `self` unchanged.
    /// Use when parsing from a single router or source.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::builder()
    ///     .single_source()  // Documents intent
    ///     .with_cache_size(1000)
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn single_source(self) -> Self {
        self
    }

    /// Creates an AutoScopedParser for multi-source deployments.
    ///
    /// **Recommended** for parsing NetFlow from multiple routers. Each source
    /// gets an isolated template cache, preventing template ID collisions.
    ///
    /// # Errors
    ///
    /// Returns `ConfigError` if the builder configuration is invalid.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    /// use std::net::SocketAddr;
    ///
    /// // Multi-source deployment
    /// let mut parser = NetflowParser::builder()
    ///     .with_cache_size(2000)
    ///     .try_multi_source()
    ///     .expect("valid config");
    ///
    /// let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();
    /// let data = [0u8; 72]; // Example data
    /// let packets = parser.parse_from_source(source, &data);
    /// ```
    ///
    /// Equivalent to:
    /// ```rust
    /// use netflow_parser::{NetflowParser, AutoScopedParser};
    ///
    /// let builder = NetflowParser::builder().with_cache_size(2000);
    /// let _parser = AutoScopedParser::try_with_builder(builder).expect("valid config");
    /// ```
    pub fn try_multi_source(self) -> Result<AutoScopedParser, ConfigError> {
        AutoScopedParser::try_with_builder(self)
    }

    /// Registers a callback for template lifecycle events.
    ///
    /// This allows you to monitor template operations in real-time, including:
    /// - Template learning (new templates added to cache)
    /// - Template collisions (template ID reused)
    /// - Template evictions (LRU policy removed template)
    /// - Template expirations (TTL-based removal)
    /// - Missing templates (data packet for unknown template)
    ///
    /// # Arguments
    ///
    /// * `hook` - A closure that will be called for each template event
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::{NetflowParser, TemplateEvent, TemplateProtocol};
    ///
    /// let parser = NetflowParser::builder()
    ///     .on_template_event(|event| {
    ///         match event {
    ///             TemplateEvent::Learned { template_id, protocol } => {
    ///                 println!("Learned template {:?}", template_id);
    ///             }
    ///             TemplateEvent::Collision { template_id, protocol } => {
    ///                 eprintln!("Template collision: {:?}", template_id);
    ///             }
    ///             _ => {}
    ///         }
    ///         Ok(())
    ///     })
    ///     .build()
    ///     .unwrap();
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn on_template_event<F>(mut self, hook: F) -> Self
    where
        F: Fn(&TemplateEvent) -> Result<(), TemplateHookError> + Send + Sync + 'static,
    {
        self.template_hooks.register(hook);
        self
    }

    /// Attach a [`TemplateStore`] to act as a secondary tier behind the parser's
    /// in-process LRU caches.
    ///
    /// With a store configured, the parser writes through every successfully
    /// learned template to the store and consults the store on every cache
    /// miss before declaring a template unknown. This lets multiple parser
    /// instances behind a UDP load balancer share template state without
    /// requiring source-IP-affinity routing.
    ///
    /// The store sees opaque `Vec<u8>` payloads encoded with a small custom
    /// binary wire format documented in the [`template_store`] module. See
    /// [`TemplateStore`] for the trait contract and threading model.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::{NetflowParser, InMemoryTemplateStore};
    /// use std::sync::Arc;
    ///
    /// let store = Arc::new(InMemoryTemplateStore::new());
    /// let parser = NetflowParser::builder()
    ///     .with_template_store(store)
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_template_store(mut self, store: Arc<dyn TemplateStore>) -> Self {
        self.template_store = Some(store);
        self
    }

    /// Set the scope string written into every [`TemplateStoreKey`].
    ///
    /// Defaults to the empty string, which is appropriate for single-source
    /// deployments. For multi-source deployments
    /// [`AutoScopedParser`] automatically populates this with the source
    /// `SocketAddr` of each per-source parser, so callers usually do not need
    /// to set this directly.
    ///
    /// Accepts anything `Into<Arc<str>>` — typically `&str` or `String`.
    #[must_use = "builder methods consume self and return a new builder; the return value must be used"]
    pub fn with_template_store_scope(mut self, scope: impl Into<Arc<str>>) -> Self {
        self.template_store_scope = scope.into();
        self
    }

    /// Validates the builder configuration without constructing a parser.
    ///
    /// This is cheaper than [`build`](Self::build) since it only checks that
    /// config values are valid (e.g., non-zero cache sizes) without allocating
    /// parser internals.
    ///
    /// # Errors
    ///
    /// Returns `ConfigError` if the configuration is invalid.
    pub fn validate(&self) -> Result<(), ConfigError> {
        V9Parser::validate_config(&self.v9_config)?;
        IPFixParser::validate_config(&self.ipfix_config)?;
        // Check that all requested versions are supported (5, 7, 9, 10)
        if let Some(versions) = &self.requested_versions {
            if versions.is_empty() {
                return Err(ConfigError::EmptyAllowedVersions);
            }
            for &v in versions {
                if !matches!(v, 5 | 7 | 9 | 10) {
                    return Err(ConfigError::InvalidAllowedVersion(v));
                }
            }
        }
        Ok(())
    }

    /// Builds the configured [`NetflowParser`].
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Template cache size is 0
    /// - Parser initialization fails
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::builder()
    ///     .with_cache_size(2000)
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    pub fn build(self) -> Result<NetflowParser, ConfigError> {
        self.validate()?;
        let mut v9_config = self.v9_config;
        let mut ipfix_config = self.ipfix_config;
        v9_config.template_store = self.template_store.clone();
        v9_config.template_store_scope = Arc::clone(&self.template_store_scope);
        ipfix_config.template_store = self.template_store;
        ipfix_config.template_store_scope = self.template_store_scope;
        let v9_parser = V9Parser::try_new(v9_config)?;
        let ipfix_parser = IPFixParser::try_new(ipfix_config)?;

        Ok(NetflowParser {
            v9_parser,
            ipfix_parser,
            allowed_versions: self.allowed_versions,
            max_error_sample_size: self.max_error_sample_size,
            template_hooks: self.template_hooks,
        })
    }
}

#[derive(Debug, Clone)]
pub(crate) enum ParsedNetflow<'a> {
    Success {
        packet: NetflowPacket,
        remaining: &'a [u8],
    },
    Error {
        error: NetflowError,
    },
    UnallowedVersion {
        version: u16,
    },
}

/// Comprehensive error type for NetFlow parsing operations.
///
/// Provides rich context about parsing failures including offset, error kind,
/// and relevant data for debugging.
#[non_exhaustive]
#[derive(Debug, PartialEq, Clone, Serialize)]
pub enum NetflowError {
    /// Incomplete data - more bytes needed to parse a complete packet.
    ///
    /// Contains the number of bytes available and a description of what was expected.
    Incomplete {
        /// Number of bytes that were available
        available: usize,
        /// Description of what was being parsed
        context: String,
    },

    /// Unknown or unsupported NetFlow version encountered.
    ///
    /// The version number found in the packet header doesn't match any known
    /// NetFlow version (V5, V7, V9, IPFIX).
    UnsupportedVersion {
        /// The version number found in the packet
        version: u16,
        /// Offset in bytes where the version was found
        offset: usize,
        /// Sample of the packet data for debugging
        sample: Vec<u8>,
    },

    /// Version is valid but filtered out by `allowed_versions` configuration.
    ///
    /// The parser was configured to only accept certain versions and this
    /// version was explicitly excluded.
    FilteredVersion {
        /// The version number that was filtered
        version: u16,
    },

    /// Parsing error with detailed context.
    ///
    /// Generic parsing failure with information about what failed and where.
    ParseError {
        /// Offset in bytes where the error occurred
        offset: usize,
        /// Description of what was being parsed
        context: String,
        /// The specific error kind
        kind: String,
        /// Sample of remaining data for debugging
        remaining: Vec<u8>,
    },

    /// Partial parse - some data was parsed but errors occurred.
    ///
    /// Used when processing continues despite errors (e.g., some flowsets
    /// parsed successfully but others failed).
    Partial {
        /// Description of the partial parse result
        message: String,
    },
}

impl std::fmt::Display for NetflowError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NetflowError::Incomplete { available, context } => {
                write!(
                    f,
                    "Incomplete data: {} (only {} bytes available)",
                    context, available
                )
            }
            NetflowError::UnsupportedVersion {
                version, offset, ..
            } => {
                write!(
                    f,
                    "Unsupported NetFlow version {} at offset {}",
                    version, offset
                )
            }
            NetflowError::FilteredVersion { version } => {
                write!(
                    f,
                    "NetFlow version {} filtered out by allowed_versions configuration",
                    version
                )
            }
            NetflowError::ParseError {
                offset,
                context,
                kind,
                ..
            } => {
                write!(
                    f,
                    "Parse error at offset {}: {} ({})",
                    offset, context, kind
                )
            }
            NetflowError::Partial { message } => {
                write!(f, "Partial parse error: {}", message)
            }
        }
    }
}

impl std::error::Error for NetflowError {}

/// Iterator that yields NetflowPacket items from a byte buffer without allocating a Vec.
/// Maintains parser state for template caching (V9/IPFIX).
pub struct NetflowPacketIterator<'a> {
    parser: &'a mut NetflowParser,
    remaining: &'a [u8],
    errored: bool,
}

impl std::fmt::Debug for NetflowPacketIterator<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NetflowPacketIterator")
            .field("remaining_bytes", &self.remaining.len())
            .field("errored", &self.errored)
            .finish()
    }
}

impl<'a> NetflowPacketIterator<'a> {
    /// Returns the unconsumed bytes remaining in the buffer.
    ///
    /// This is useful for:
    /// - Debugging: See how much data was consumed
    /// - Mixed protocols: Process non-netflow data after netflow packets
    /// - Resumption: Know where parsing stopped
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let v5_packet = [0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,];
    /// let mut parser = NetflowParser::default();
    /// let mut iter = parser.iter_packets(&v5_packet);
    ///
    /// while let Some(_packet) = iter.next() {
    ///     // Process packet
    /// }
    ///
    /// // Check how many bytes remain unconsumed
    /// assert_eq!(iter.remaining().len(), 0);
    /// ```
    pub fn remaining(&self) -> &'a [u8] {
        self.remaining
    }

    /// Returns true if all bytes have been consumed or an error occurred.
    ///
    /// This is useful for validation and ensuring complete buffer processing.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let v5_packet = [0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,];
    /// let mut parser = NetflowParser::default();
    /// let mut iter = parser.iter_packets(&v5_packet);
    ///
    /// // Consume all packets
    /// for _packet in &mut iter {
    ///     // Process packet
    /// }
    ///
    /// assert!(iter.is_complete());
    /// ```
    pub fn is_complete(&self) -> bool {
        self.remaining.is_empty() || self.errored
    }
}

impl<'a> Iterator for NetflowPacketIterator<'a> {
    type Item = Result<NetflowPacket, NetflowError>;

    fn next(&mut self) -> Option<Self::Item> {
        // Stop if we've errored or no bytes remain
        if self.errored || self.remaining.is_empty() {
            return None;
        }

        match self.parser.parse_packet_by_version(self.remaining) {
            ParsedNetflow::Success {
                packet,
                remaining: new_remaining,
            } => {
                self.remaining = new_remaining;
                Some(Ok(packet))
            }
            ParsedNetflow::UnallowedVersion { version } => {
                self.errored = true;
                self.remaining = &[];
                Some(Err(NetflowError::FilteredVersion { version }))
            }
            ParsedNetflow::Error { error } => {
                self.errored = true;
                self.remaining = &[];
                Some(Err(error))
            }
        }
    }
}

impl Default for NetflowParser {
    fn default() -> Self {
        Self {
            v9_parser: V9Parser::default(),
            ipfix_parser: IPFixParser::default(),
            allowed_versions: versions_to_array(&[5, 7, 9, 10]),
            max_error_sample_size: 256,
            template_hooks: TemplateHooks::new(),
        }
    }
}

impl NetflowParser {
    /// Creates a new builder for configuring a [`NetflowParser`].
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    /// use netflow_parser::variable_versions::ttl::TtlConfig;
    /// use std::time::Duration;
    ///
    /// let parser = NetflowParser::builder()
    ///     .with_cache_size(2000)
    ///     .with_ttl(TtlConfig::new(Duration::from_secs(7200)))
    ///     .build()
    ///     .expect("Failed to build parser");
    /// ```
    pub fn builder() -> NetflowParserBuilder {
        NetflowParserBuilder::default()
    }

    /// Override the scope string used for [`TemplateStore`] reads/writes by
    /// the underlying V9 and IPFIX parsers.
    ///
    /// Used by [`AutoScopedParser`] to give each per-source parser a scope
    /// derived from the exporter's `SocketAddr`. Callers managing their own
    /// per-source parsers may also use this to retrofit a scope after the
    /// builder has produced a parser.
    ///
    /// Accepts anything `Into<Arc<str>>` — typically `&str` or `String`.
    pub fn set_template_store_scope(&mut self, scope: impl Into<Arc<str>>) {
        let scope: Arc<str> = scope.into();
        self.v9_parser.set_template_store_scope(Arc::clone(&scope));
        self.ipfix_parser.set_template_store_scope(scope);
    }

    /// Returns the allowed versions array.
    ///
    /// Indexed by version number: index 5 = V5, 7 = V7, 9 = V9, 10 = IPFIX.
    /// `true` means the version is accepted for parsing.
    pub fn allowed_versions(&self) -> &[bool; 11] {
        &self.allowed_versions
    }

    /// Returns whether the given NetFlow version is allowed for parsing.
    ///
    /// Returns `false` for version numbers outside the supported range (0–10).
    pub fn is_version_allowed(&self, version: u16) -> bool {
        (version as usize) < self.allowed_versions.len()
            && self.allowed_versions[version as usize]
    }

    /// Returns the maximum error sample size in bytes.
    pub fn max_error_sample_size(&self) -> usize {
        self.max_error_sample_size
    }

    /// Returns a reference to the V9 parser.
    pub fn v9_parser(&self) -> &V9Parser {
        &self.v9_parser
    }

    /// Returns a mutable reference to the V9 parser.
    pub fn v9_parser_mut(&mut self) -> &mut V9Parser {
        &mut self.v9_parser
    }

    /// Returns a reference to the IPFIX parser.
    pub fn ipfix_parser(&self) -> &IPFixParser {
        &self.ipfix_parser
    }

    /// Returns a mutable reference to the IPFIX parser.
    pub fn ipfix_parser_mut(&mut self) -> &mut IPFixParser {
        &mut self.ipfix_parser
    }

    /// Gets statistics about the V9 template cache.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::default();
    /// let stats = parser.v9_cache_info();
    /// println!("V9 cache: {}/{} templates", stats.current_size, stats.max_size_per_cache);
    /// ```
    pub fn v9_cache_info(&self) -> CacheInfo {
        CacheInfo {
            current_size: count_valid_templates(
                &self.v9_parser.templates,
                &self.v9_parser.ttl_config,
            ) + count_valid_templates(
                &self.v9_parser.options_templates,
                &self.v9_parser.ttl_config,
            ),
            max_size_per_cache: self.v9_parser.max_template_cache_size,
            num_caches: 2,
            ttl_config: self.v9_parser.ttl_config.clone(),
            metrics: self.v9_parser.metrics.snapshot(),
            pending_flow_count: self.v9_parser.pending_flow_count(),
        }
    }

    /// Gets statistics about the IPFIX template cache.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::default();
    /// let stats = parser.ipfix_cache_info();
    /// println!("IPFIX cache: {}/{} templates", stats.current_size, stats.max_size_per_cache);
    /// ```
    pub fn ipfix_cache_info(&self) -> CacheInfo {
        let ttl = &self.ipfix_parser.ttl_config;
        CacheInfo {
            current_size: count_valid_templates(&self.ipfix_parser.templates, ttl)
                + count_valid_templates(&self.ipfix_parser.v9_templates, ttl)
                + count_valid_templates(&self.ipfix_parser.ipfix_options_templates, ttl)
                + count_valid_templates(&self.ipfix_parser.v9_options_templates, ttl),
            max_size_per_cache: self.ipfix_parser.max_template_cache_size,
            num_caches: 4,
            ttl_config: self.ipfix_parser.ttl_config.clone(),
            metrics: self.ipfix_parser.metrics.snapshot(),
            pending_flow_count: self.ipfix_parser.pending_flow_count(),
        }
    }

    /// Lists all cached V9 template IDs.
    ///
    /// Note: This returns template IDs from both regular and options templates.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::default();
    /// let template_ids = parser.v9_template_ids();
    /// println!("Cached V9 templates: {:?}", template_ids);
    /// ```
    pub fn v9_template_ids(&self) -> Vec<u16> {
        let mut ids: Vec<u16> = self.v9_parser.templates.iter().map(|(id, _)| *id).collect();
        ids.extend(self.v9_parser.options_templates.iter().map(|(id, _)| *id));
        ids.sort_unstable();
        ids.dedup();
        ids
    }

    /// Lists all cached IPFIX template IDs.
    ///
    /// Note: This returns template IDs from both IPFIX and V9-format templates (IPFIX can contain both).
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::default();
    /// let template_ids = parser.ipfix_template_ids();
    /// println!("Cached IPFIX templates: {:?}", template_ids);
    /// ```
    pub fn ipfix_template_ids(&self) -> Vec<u16> {
        let mut ids: Vec<u16> = self
            .ipfix_parser
            .templates
            .iter()
            .map(|(id, _)| *id)
            .collect();
        ids.extend(self.ipfix_parser.v9_templates.iter().map(|(id, _)| *id));
        ids.extend(
            self.ipfix_parser
                .ipfix_options_templates
                .iter()
                .map(|(id, _)| *id),
        );
        ids.extend(
            self.ipfix_parser
                .v9_options_templates
                .iter()
                .map(|(id, _)| *id),
        );
        ids.sort_unstable();
        ids.dedup();
        ids
    }

    /// Checks if a V9 template with the given ID is cached.
    ///
    /// Note: This uses `peek()` which does not affect LRU ordering.
    ///
    /// # Arguments
    ///
    /// * `template_id` - The template ID to check
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::default();
    /// if parser.has_v9_template(256) {
    ///     println!("Template 256 is cached");
    /// }
    /// ```
    pub fn has_v9_template(&self, template_id: u16) -> bool {
        self.v9_parser
            .templates
            .peek(&template_id)
            .is_some_and(|t| {
                self.v9_parser
                    .ttl_config
                    .as_ref()
                    .is_none_or(|cfg| !t.is_expired(cfg))
            })
            || self
                .v9_parser
                .options_templates
                .peek(&template_id)
                .is_some_and(|t| {
                    self.v9_parser
                        .ttl_config
                        .as_ref()
                        .is_none_or(|cfg| !t.is_expired(cfg))
                })
    }

    /// Checks if an IPFIX template with the given ID is cached.
    ///
    /// Note: This uses `peek()` which does not affect LRU ordering.
    ///
    /// # Arguments
    ///
    /// * `template_id` - The template ID to check
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let parser = NetflowParser::default();
    /// if parser.has_ipfix_template(256) {
    ///     println!("Template 256 is cached");
    /// }
    /// ```
    pub fn has_ipfix_template(&self, template_id: u16) -> bool {
        let ttl = &self.ipfix_parser.ttl_config;
        self.ipfix_parser
            .templates
            .peek(&template_id)
            .is_some_and(|t| ttl.as_ref().is_none_or(|cfg| !t.is_expired(cfg)))
            || self
                .ipfix_parser
                .v9_templates
                .peek(&template_id)
                .is_some_and(|t| ttl.as_ref().is_none_or(|cfg| !t.is_expired(cfg)))
            || self
                .ipfix_parser
                .ipfix_options_templates
                .peek(&template_id)
                .is_some_and(|t| ttl.as_ref().is_none_or(|cfg| !t.is_expired(cfg)))
            || self
                .ipfix_parser
                .v9_options_templates
                .peek(&template_id)
                .is_some_and(|t| ttl.as_ref().is_none_or(|cfg| !t.is_expired(cfg)))
    }

    /// Clears all cached V9 templates.
    ///
    /// This is useful for testing or when you need to force template re-learning.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let mut parser = NetflowParser::default();
    /// parser.clear_v9_templates();
    /// ```
    pub fn clear_v9_templates(&mut self) {
        // Mirror to the secondary store first (best-effort) so that
        // subsequent reads do not transparently repopulate the in-process
        // cache via read-through.
        if let Some(store) = self.v9_parser.template_store.clone() {
            let scope = self.v9_parser.template_store_scope.clone();
            for (id, _) in self.v9_parser.templates.iter() {
                let _ = store.remove(&template_store::TemplateStoreKey::new(
                    scope.clone(),
                    template_store::TemplateKind::V9Data,
                    *id,
                ));
            }
            for (id, _) in self.v9_parser.options_templates.iter() {
                let _ = store.remove(&template_store::TemplateStoreKey::new(
                    scope.clone(),
                    template_store::TemplateKind::V9Options,
                    *id,
                ));
            }
        }
        self.v9_parser.templates.clear();
        self.v9_parser.options_templates.clear();
        self.v9_parser.clear_pending_flows();
    }

    /// Clears all cached IPFIX templates.
    ///
    /// This is useful for testing or when you need to force template re-learning.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let mut parser = NetflowParser::default();
    /// parser.clear_ipfix_templates();
    /// ```
    pub fn clear_ipfix_templates(&mut self) {
        if let Some(store) = self.ipfix_parser.template_store.clone() {
            let scope = self.ipfix_parser.template_store_scope.clone();
            for (id, _) in self.ipfix_parser.templates.iter() {
                let _ = store.remove(&template_store::TemplateStoreKey::new(
                    scope.clone(),
                    template_store::TemplateKind::IpfixData,
                    *id,
                ));
            }
            for (id, _) in self.ipfix_parser.ipfix_options_templates.iter() {
                let _ = store.remove(&template_store::TemplateStoreKey::new(
                    scope.clone(),
                    template_store::TemplateKind::IpfixOptions,
                    *id,
                ));
            }
            for (id, _) in self.ipfix_parser.v9_templates.iter() {
                let _ = store.remove(&template_store::TemplateStoreKey::new(
                    scope.clone(),
                    template_store::TemplateKind::IpfixV9Data,
                    *id,
                ));
            }
            for (id, _) in self.ipfix_parser.v9_options_templates.iter() {
                let _ = store.remove(&template_store::TemplateStoreKey::new(
                    scope.clone(),
                    template_store::TemplateKind::IpfixV9Options,
                    *id,
                ));
            }
        }
        self.ipfix_parser.templates.clear();
        self.ipfix_parser.v9_templates.clear();
        self.ipfix_parser.ipfix_options_templates.clear();
        self.ipfix_parser.v9_options_templates.clear();
        self.ipfix_parser.clear_pending_flows();
    }

    /// Clears all pending V9 flows.
    pub fn clear_v9_pending_flows(&mut self) {
        self.v9_parser.clear_pending_flows();
    }

    /// Clears all pending IPFIX flows.
    pub fn clear_ipfix_pending_flows(&mut self) {
        self.ipfix_parser.clear_pending_flows();
    }

    /// Triggers template event hooks.
    ///
    /// This method is called internally by template operations to notify
    /// registered hooks about template lifecycle events. It can also be called
    /// manually for testing or custom integration scenarios.
    ///
    /// # Arguments
    ///
    /// * `event` - The template event to trigger
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::{NetflowParser, TemplateEvent, TemplateProtocol};
    ///
    /// let mut parser = NetflowParser::default();
    /// parser.trigger_template_event(TemplateEvent::Learned {
    ///     template_id: Some(256),
    ///     protocol: TemplateProtocol::V9,
    /// });
    /// ```
    #[inline]
    pub fn trigger_template_event(&mut self, event: TemplateEvent) {
        self.template_hooks.trigger(&event);
    }

    /// Returns the total number of hook errors and panics encountered.
    ///
    /// Useful for monitoring hook health in production without affecting parsing.
    #[inline]
    pub fn hook_error_count(&self) -> u64 {
        self.template_hooks.hook_error_count()
    }

    /// Parses NetFlow packets from a byte slice, preserving all successfully parsed packets.
    ///
    /// This function parses packets in sequence and returns a [`ParseResult`] containing both
    /// successfully parsed packets and an optional error. **No data is lost** - if parsing fails
    /// partway through, you still get all packets parsed before the error.
    ///
    /// # Arguments
    ///
    /// * `packet` - Byte slice containing NetFlow packet(s)
    ///
    /// # Returns
    ///
    /// [`ParseResult`] with:
    /// * `packets` - All successfully parsed packets (even if error occurred)
    /// * `error` - `None` if fully successful, `Some(error)` if parsing stopped
    ///
    /// # Examples
    ///
    /// ## Basic usage
    ///
    /// ```rust
    /// use netflow_parser::NetflowParser;
    ///
    /// let v5_packet = [0, 5, 2, 0, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,];
    /// let result = NetflowParser::default().parse_bytes(&v5_packet);
    ///
    /// // Process all packets
    /// for packet in result.packets {
    ///     println!("Parsed packet");
    /// }
    ///
    /// // Check for errors
    /// if let Some(e) = result.error {
    ///     eprintln!("Error: {}", e);
    /// }
    /// ```
    ///
    /// ## With JSON serialization
    ///
    /// ```rust
    /// use serde_json::json;
    /// use netflow_parser::NetflowParser;
    ///
    /// let v5_packet = [0, 5, 2, 0, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,];
    /// let result = NetflowParser::default().parse_bytes(&v5_packet);
    /// println!("{}", json!(result.packets).to_string());
    /// ```
    ///
    #[inline]
    pub fn parse_bytes(&mut self, packet: &[u8]) -> ParseResult {
        if packet.is_empty() {
            return ParseResult {
                packets: vec![],
                error: None,
            };
        }

        let mut packets = Vec::new();
        let mut remaining = packet;
        let mut error = None;

        while !remaining.is_empty() {
            match self.parse_packet_by_version(remaining) {
                ParsedNetflow::Success {
                    packet,
                    remaining: new_remaining,
                } => {
                    packets.push(packet);
                    remaining = new_remaining;
                }
                ParsedNetflow::UnallowedVersion { version } => {
                    error = Some(NetflowError::FilteredVersion { version });
                    break;
                }
                ParsedNetflow::Error { error: e } => {
                    // Store error but keep successfully parsed packets
                    error = Some(e);
                    break;
                }
            }
        }

        ParseResult { packets, error }
    }

    /// Returns an iterator that yields NetflowPacket items without allocating a Vec.
    /// This is useful for processing large batches of packets without collecting all results in memory.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::{NetflowParser, NetflowPacket};
    ///
    /// let v5_packet = [0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,];
    /// let mut parser = NetflowParser::default();
    ///
    /// for result in parser.iter_packets(&v5_packet) {
    ///     match result {
    ///         Ok(NetflowPacket::V5(v5)) => println!("V5 packet: {:?}", v5.header.version),
    ///         Err(e) => println!("Error: {:?}", e),
    ///         _ => (),
    ///     }
    /// }
    /// ```
    #[inline]
    pub fn iter_packets<'a>(&'a mut self, packet: &'a [u8]) -> NetflowPacketIterator<'a> {
        NetflowPacketIterator {
            parser: self,
            remaining: packet,
            errored: false,
        }
    }

    #[inline]
    fn parse_packet_by_version<'a>(&mut self, packet: &'a [u8]) -> ParsedNetflow<'a> {
        // Snapshot metrics before parsing to detect collisions/evictions/expirations
        let hooks_active = !self.template_hooks.is_empty();
        let v9_metrics_before = if hooks_active {
            Some(self.v9_parser.metrics)
        } else {
            None
        };
        let ipfix_metrics_before = if hooks_active {
            Some(self.ipfix_parser.metrics)
        } else {
            None
        };

        let result = match GenericNetflowHeader::parse(packet) {
            Ok((remaining, header))
                if (header.version as usize) < self.allowed_versions.len()
                    && self.allowed_versions[header.version as usize] =>
            {
                match header.version {
                    5 => V5Parser::parse(remaining),
                    7 => V7Parser::parse(remaining),
                    9 => self.v9_parser.parse(remaining),
                    10 => self.ipfix_parser.parse(remaining),
                    // The outer guard ensures only versions with allowed_versions[v]==true
                    // reach here, and only 5/7/9/10 can be set to true via the builder.
                    _ => unreachable!("allowed_versions guard only permits 5/7/9/10"),
                }
            }
            Ok((_, header)) if matches!(header.version, 5 | 7 | 9 | 10) => {
                // Version is supported but filtered by allowed_versions
                ParsedNetflow::UnallowedVersion {
                    version: header.version,
                }
            }
            Ok((remaining, header)) => {
                // Version is not supported at all
                ParsedNetflow::Error {
                    error: NetflowError::UnsupportedVersion {
                        version: header.version,
                        offset: 0,
                        sample: remaining[..remaining.len().min(self.max_error_sample_size)]
                            .to_vec(),
                    },
                }
            }
            Err(e) => ParsedNetflow::Error {
                error: NetflowError::Incomplete {
                    available: packet.len(),
                    context: format!("NetFlow header: {}", e),
                },
            },
        };

        if hooks_active {
            if let ParsedNetflow::Success { ref packet, .. } = result {
                self.fire_template_events(packet);
            }
            // Fire Restored events for templates pulled in from the secondary
            // store during this parse. Drained from each parser whether the
            // outer result was Success or Error — restoration that happened
            // before a later flowset failed should still be reported.
            for (protocol, template_id) in self.v9_parser.drain_restored_templates() {
                self.template_hooks.trigger(&TemplateEvent::Restored {
                    template_id: Some(template_id),
                    protocol,
                });
            }
            for (protocol, template_id) in self.ipfix_parser.drain_restored_templates() {
                self.template_hooks.trigger(&TemplateEvent::Restored {
                    template_id: Some(template_id),
                    protocol,
                });
            }
            // Fire metric-based events for collisions, evictions, and expirations.
            // Copy the after-metrics to avoid borrowing self immutably while
            // fire_metric_delta_events borrows self mutably (for hook_errors).
            if let Some(before) = v9_metrics_before {
                let after = self.v9_parser.metrics;
                self.fire_metric_delta_events(&before, &after, TemplateProtocol::V9);
            }
            if let Some(before) = ipfix_metrics_before {
                let after = self.ipfix_parser.metrics;
                self.fire_metric_delta_events(&before, &after, TemplateProtocol::Ipfix);
            }
        } else {
            // Even when no hooks are registered, drain the buffers so they
            // do not accumulate across parse_bytes calls.
            let _ = self.v9_parser.drain_restored_templates();
            let _ = self.ipfix_parser.drain_restored_templates();
        }

        result
    }

    fn fire_metric_delta_events(
        &mut self,
        before: &variable_versions::metrics::CacheMetricsInner,
        after: &variable_versions::metrics::CacheMetricsInner,
        protocol: TemplateProtocol,
    ) {
        // Cap events per type per parse call to prevent hook amplification from
        // malicious packets that trigger thousands of collisions/evictions.
        const MAX_EVENTS_PER_TYPE: u64 = 64;

        let new_collisions = after
            .collisions
            .saturating_sub(before.collisions)
            .min(MAX_EVENTS_PER_TYPE);
        for _ in 0..new_collisions {
            self.template_hooks.trigger(&TemplateEvent::Collision {
                template_id: None, // specific ID not available from metrics
                protocol,
            });
        }
        let new_evictions = after
            .evictions
            .saturating_sub(before.evictions)
            .min(MAX_EVENTS_PER_TYPE);
        for _ in 0..new_evictions {
            self.template_hooks.trigger(&TemplateEvent::Evicted {
                template_id: None, // specific ID not available from metrics
                protocol,
            });
        }
        let new_expirations = after
            .expired
            .saturating_sub(before.expired)
            .min(MAX_EVENTS_PER_TYPE);
        for _ in 0..new_expirations {
            self.template_hooks.trigger(&TemplateEvent::Expired {
                template_id: None, // specific ID not available from metrics
                protocol,
            });
        }
    }

    fn fire_template_events(&mut self, packet: &NetflowPacket) {
        match packet {
            NetflowPacket::V9(v9) => {
                for fs in &v9.flowsets {
                    match &fs.body {
                        variable_versions::v9::FlowSetBody::Template(templates) => {
                            for t in &templates.templates {
                                self.template_hooks.trigger(&TemplateEvent::Learned {
                                    template_id: Some(t.template_id),
                                    protocol: TemplateProtocol::V9,
                                });
                            }
                        }
                        variable_versions::v9::FlowSetBody::OptionsTemplate(templates) => {
                            for t in &templates.templates {
                                self.template_hooks.trigger(&TemplateEvent::Learned {
                                    template_id: Some(t.template_id),
                                    protocol: TemplateProtocol::V9,
                                });
                            }
                        }
                        variable_versions::v9::FlowSetBody::NoTemplate(info) => {
                            self.template_hooks
                                .trigger(&TemplateEvent::MissingTemplate {
                                    template_id: Some(info.template_id),
                                    protocol: TemplateProtocol::V9,
                                });
                        }
                        // Data/OptionsData/Empty flowsets don't generate template events
                        variable_versions::v9::FlowSetBody::Data(_)
                        | variable_versions::v9::FlowSetBody::OptionsData(_)
                        | variable_versions::v9::FlowSetBody::Empty => {}
                    }
                }
            }
            NetflowPacket::IPFix(ipfix) => {
                for fs in &ipfix.flowsets {
                    match &fs.body {
                        variable_versions::ipfix::FlowSetBody::Template(t) => {
                            self.template_hooks.trigger(&TemplateEvent::Learned {
                                template_id: Some(t.template_id),
                                protocol: TemplateProtocol::Ipfix,
                            });
                        }
                        variable_versions::ipfix::FlowSetBody::Templates(ts) => {
                            for t in ts {
                                self.template_hooks.trigger(&TemplateEvent::Learned {
                                    template_id: Some(t.template_id),
                                    protocol: TemplateProtocol::Ipfix,
                                });
                            }
                        }
                        variable_versions::ipfix::FlowSetBody::V9Template(t) => {
                            self.template_hooks.trigger(&TemplateEvent::Learned {
                                template_id: Some(t.template_id),
                                protocol: TemplateProtocol::Ipfix,
                            });
                        }
                        variable_versions::ipfix::FlowSetBody::V9Templates(ts) => {
                            for t in ts {
                                self.template_hooks.trigger(&TemplateEvent::Learned {
                                    template_id: Some(t.template_id),
                                    protocol: TemplateProtocol::Ipfix,
                                });
                            }
                        }
                        variable_versions::ipfix::FlowSetBody::OptionsTemplate(t) => {
                            self.template_hooks.trigger(&TemplateEvent::Learned {
                                template_id: Some(t.template_id),
                                protocol: TemplateProtocol::Ipfix,
                            });
                        }
                        variable_versions::ipfix::FlowSetBody::OptionsTemplates(ts) => {
                            for t in ts {
                                self.template_hooks.trigger(&TemplateEvent::Learned {
                                    template_id: Some(t.template_id),
                                    protocol: TemplateProtocol::Ipfix,
                                });
                            }
                        }
                        variable_versions::ipfix::FlowSetBody::V9OptionsTemplate(t) => {
                            self.template_hooks.trigger(&TemplateEvent::Learned {
                                template_id: Some(t.template_id),
                                protocol: TemplateProtocol::Ipfix,
                            });
                        }
                        variable_versions::ipfix::FlowSetBody::V9OptionsTemplates(ts) => {
                            for t in ts {
                                self.template_hooks.trigger(&TemplateEvent::Learned {
                                    template_id: Some(t.template_id),
                                    protocol: TemplateProtocol::Ipfix,
                                });
                            }
                        }
                        variable_versions::ipfix::FlowSetBody::NoTemplate(info) => {
                            self.template_hooks
                                .trigger(&TemplateEvent::MissingTemplate {
                                    template_id: Some(info.template_id),
                                    protocol: TemplateProtocol::Ipfix,
                                });
                        }
                        // Data flowsets and empty sets don't generate template events
                        variable_versions::ipfix::FlowSetBody::Data(_)
                        | variable_versions::ipfix::FlowSetBody::OptionsData(_)
                        | variable_versions::ipfix::FlowSetBody::V9Data(_)
                        | variable_versions::ipfix::FlowSetBody::V9OptionsData(_)
                        | variable_versions::ipfix::FlowSetBody::Empty => {}
                    }
                }
            }
            // V5/V7 are static versions with no template system
            NetflowPacket::V5(_) | NetflowPacket::V7(_) => {}
        }
    }

    /// Takes a Netflow packet slice and returns parsed [`NetflowCommonFlowSet`]s
    /// along with any parse error.
    ///
    /// Packets that fail `as_netflow_common()` conversion (e.g., V9/IPFIX data
    /// flowsets without matching templates) are skipped. The returned error, if
    /// any, comes from the underlying [`parse_bytes`](Self::parse_bytes) call.
    #[cfg(feature = "netflow_common")]
    #[inline]
    pub fn parse_bytes_as_netflow_common_flowsets(
        &mut self,
        packet: &[u8],
    ) -> (Vec<NetflowCommonFlowSet>, Option<NetflowError>) {
        let netflow_packets = self.parse_bytes(packet);
        let flowsets = netflow_packets
            .packets
            .iter()
            .flat_map(|n| n.as_netflow_common().unwrap_or_default().flowsets)
            .collect();
        (flowsets, netflow_packets.error)
    }
}
