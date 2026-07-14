//! Parser configuration, traits, and constants for V9 and IPFIX parsers.

use super::metrics::CacheMetricsInner;
use super::pending_flows::{PendingFlowCache, PendingFlowsConfig};
use crate::template_store::TemplateStore;
use crate::variable_versions::enterprise_registry::EnterpriseFieldRegistry;
use crate::variable_versions::ttl::TtlConfig;
use std::num::NonZeroUsize;
use std::sync::Arc;

/// Default maximum number of templates to cache per parser
pub const DEFAULT_MAX_TEMPLATE_CACHE_SIZE: usize = 1000;
const _: () = assert!(DEFAULT_MAX_TEMPLATE_CACHE_SIZE > 0);

pub(crate) type TemplateId = u16;

/// Default maximum number of fields allowed per template to prevent DoS attacks.
/// A reasonable limit that should accommodate legitimate use cases.
/// This can be configured per-parser via the Config struct.
pub const MAX_FIELD_COUNT: usize = 10_000;

/// Default maximum number of data records to parse per flowset.
/// This prevents CPU-bound DoS from maliciously large flowsets.
pub const DEFAULT_MAX_RECORDS_PER_FLOWSET: usize = 1024;

/// Configuration for V9 and IPFIX parsers.
///
/// Controls template cache size, field limits, TTL, enterprise field definitions,
/// and pending flow caching. Use [`Config::new`] for defaults or construct directly
/// for full control.
#[non_exhaustive]
#[derive(Debug, Clone)]
pub struct Config {
    /// Maximum number of templates to keep in the LRU cache.
    pub max_template_cache_size: usize,
    /// Maximum number of fields allowed per template. Default: 10,000.
    pub max_field_count: usize,
    /// Maximum total size (in bytes) of all fields in a template.
    /// This prevents DoS attacks via templates with excessive total field lengths.
    /// Default: u16::MAX
    pub max_template_total_size: usize,
    /// Maximum number of bytes to include in error samples to prevent memory exhaustion.
    /// Defaults to 256 bytes.
    pub max_error_sample_size: usize,
    /// Maximum number of data records to parse per flowset. Default: 1,024.
    /// This prevents CPU-bound DoS from maliciously large flowsets.
    pub max_records_per_flowset: usize,
    /// Optional TTL configuration for template expiration.
    pub ttl_config: Option<TtlConfig>,
    /// Registry of custom enterprise-specific field definitions for IPFIX.
    ///
    /// Wrapped in `Arc` so that cloning a `Config` (e.g., for each new source
    /// in a scoped parser) shares the registry rather than deep-copying the
    /// entire `HashMap`.
    pub enterprise_registry: Arc<EnterpriseFieldRegistry>,
    /// Configuration for pending flow caching. `None` means disabled (default).
    pub pending_flows_config: Option<PendingFlowsConfig>,
    /// Optional secondary-tier [`TemplateStore`] for sharing parsed templates
    /// across parser instances. `None` means the parser uses only its
    /// in-process LRU (default behavior).
    ///
    /// See [`crate::template_store`] for the read-through / write-through
    /// protocol the parser implements on top of this trait.
    pub template_store: Option<Arc<dyn TemplateStore>>,
    /// Scope string written into every [`crate::template_store::TemplateStoreKey`].
    /// Empty for single-source deployments. Multi-source parsers
    /// (`AutoScopedParser`) override this per source. Stored as `Arc<str>`
    /// so the parser can clone it cheaply per store key.
    pub template_store_scope: Arc<str>,
}

#[non_exhaustive]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    /// Template cache size must be greater than 0
    InvalidCacheSize(usize),
    /// Pending flow cache size must be greater than 0
    InvalidPendingCacheSize(usize),
    /// An allowed version number is out of the supported range (0-10)
    InvalidAllowedVersion(u16),
    /// Max field count must be greater than 0
    InvalidFieldCount(usize),
    /// Max template total size must be greater than 0
    InvalidTemplateTotalSize(usize),
    /// Pending flow max entries per template must be greater than 0
    InvalidEntriesPerTemplate(usize),
    /// Pending flow max entry size must be between 1 and 65531 (u16::MAX - 4)
    InvalidEntrySize(usize),
    /// TTL duration must be greater than zero
    InvalidTtlDuration,
    /// Allowed versions list must not be empty
    EmptyAllowedVersions,
    /// Max records per flowset must be greater than 0
    InvalidRecordsPerFlowset(usize),
    /// Pending flow max_total_bytes must be >= max_entry_size_bytes
    InvalidPendingTotalBytes {
        max_total_bytes: usize,
        max_entry_size_bytes: usize,
    },
    /// max_sources must be greater than 0
    InvalidMaxSources(usize),
    /// max_error_sample_size must be greater than 0
    InvalidErrorSampleSize(usize),
}

impl std::error::Error for ConfigError {}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::InvalidCacheSize(size) => {
                write!(
                    f,
                    "Invalid template cache size: {}. Must be greater than 0.",
                    size
                )
            }
            ConfigError::InvalidPendingCacheSize(size) => {
                write!(
                    f,
                    "Invalid pending flow cache size: {}. Must be greater than 0.",
                    size
                )
            }
            ConfigError::InvalidAllowedVersion(version) => {
                write!(
                    f,
                    "Invalid allowed version: {}. Supported versions are 5, 7, 9, 10.",
                    version
                )
            }
            ConfigError::InvalidFieldCount(count) => {
                write!(
                    f,
                    "Invalid max field count: {}. Must be greater than 0.",
                    count
                )
            }
            ConfigError::InvalidTemplateTotalSize(size) => {
                write!(
                    f,
                    "Invalid max template total size: {}. Must be greater than 0.",
                    size
                )
            }
            ConfigError::InvalidEntriesPerTemplate(count) => {
                write!(
                    f,
                    "Invalid max entries per template: {}. Must be greater than 0.",
                    count
                )
            }
            ConfigError::InvalidEntrySize(size) => {
                write!(
                    f,
                    "Invalid max entry size: {}. Must be between 1 and 65531 (u16::MAX - 4).",
                    size
                )
            }
            ConfigError::InvalidTtlDuration => {
                write!(f, "Invalid TTL duration: must be greater than zero.")
            }
            ConfigError::InvalidRecordsPerFlowset(count) => {
                write!(
                    f,
                    "Invalid max records per flowset: {}. Must be greater than 0.",
                    count
                )
            }
            ConfigError::EmptyAllowedVersions => {
                write!(
                    f,
                    "Allowed versions list must not be empty. Supported versions are 5, 7, 9, 10."
                )
            }
            ConfigError::InvalidPendingTotalBytes {
                max_total_bytes,
                max_entry_size_bytes,
            } => {
                write!(
                    f,
                    "Invalid pending flow config: max_total_bytes ({}) must be >= max_entry_size_bytes ({}).",
                    max_total_bytes, max_entry_size_bytes
                )
            }
            ConfigError::InvalidMaxSources(size) => {
                write!(f, "Invalid max_sources: {}. Must be greater than 0.", size)
            }
            ConfigError::InvalidErrorSampleSize(size) => {
                write!(
                    f,
                    "Invalid max_error_sample_size: {}. Must be greater than 0.",
                    size
                )
            }
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_template_cache_size: DEFAULT_MAX_TEMPLATE_CACHE_SIZE,
            max_field_count: MAX_FIELD_COUNT,
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset: DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: Arc::from(""),
        }
    }
}

impl Config {
    /// Creates a new `Config` with the given cache size and optional TTL.
    /// Other fields use defaults (field count: 10,000, no enterprise registry, no pending flows).
    pub fn new(max_template_cache_size: usize, ttl_config: Option<TtlConfig>) -> Self {
        Self {
            max_template_cache_size,
            ttl_config,
            ..Self::default()
        }
    }

    /// Creates a new `Config` with a custom enterprise field registry.
    /// Useful for IPFIX parsers that need to decode vendor-specific information elements.
    pub fn with_enterprise_registry(
        max_template_cache_size: usize,
        ttl_config: Option<TtlConfig>,
        enterprise_registry: EnterpriseFieldRegistry,
    ) -> Self {
        Self {
            enterprise_registry: Arc::new(enterprise_registry),
            ..Self::new(max_template_cache_size, ttl_config)
        }
    }

    /// Validate this configuration, returning an error if any field has an invalid value.
    ///
    /// This performs the same checks as [`ParserConfig::add_config`] but without
    /// requiring a parser instance, allowing early validation.
    pub fn validate(&self) -> Result<(), ConfigError> {
        NonZeroUsize::new(self.max_template_cache_size)
            .ok_or(ConfigError::InvalidCacheSize(self.max_template_cache_size))?;
        if self.max_field_count == 0 {
            return Err(ConfigError::InvalidFieldCount(0));
        }
        if self.max_template_total_size == 0 {
            return Err(ConfigError::InvalidTemplateTotalSize(0));
        }
        if self.max_records_per_flowset == 0 {
            return Err(ConfigError::InvalidRecordsPerFlowset(0));
        }
        if self.max_error_sample_size == 0 {
            return Err(ConfigError::InvalidErrorSampleSize(0));
        }
        if let Some(ref ttl) = self.ttl_config
            && ttl.duration.is_zero()
        {
            return Err(ConfigError::InvalidTtlDuration);
        }
        if let Some(ref pf) = self.pending_flows_config {
            PendingFlowCache::validate_config(pf)?;
        }
        Ok(())
    }
}

/// Internal accessor trait for shared parser fields.
///
/// Both V9Parser and IPFixParser share the same config/state fields. This trait
/// provides access so that `ParserConfig` can supply default implementations.
pub(crate) trait ParserFields {
    fn set_max_template_cache_size_field(&mut self, size: usize);
    fn set_max_field_count_field(&mut self, count: usize);
    fn set_max_template_total_size_field(&mut self, size: usize);
    fn set_max_error_sample_size_field(&mut self, size: usize);
    fn set_max_records_per_flowset_field(&mut self, count: usize);
    fn set_ttl_config_field(&mut self, config: Option<TtlConfig>);
    /// Apply an enterprise registry update. Default is a no-op (V9 has no registry).
    fn set_enterprise_registry(&mut self, _registry: Arc<EnterpriseFieldRegistry>) {}
    fn pending_flows(&self) -> &Option<PendingFlowCache>;
    fn pending_flows_mut(&mut self) -> &mut Option<PendingFlowCache>;
    fn metrics_mut(&mut self) -> &mut CacheMetricsInner;
}

/// Trait for parsers that support template caching and TTL configuration
#[allow(private_bounds)]
pub trait ParserConfig: ParserFields {
    /// Internal helper: resize all template caches to the given size
    fn resize_template_caches(&mut self, cache_size: NonZeroUsize);

    /// Add or update the parser's configuration
    fn add_config(&mut self, config: Config) -> Result<(), ConfigError> {
        // Validate everything before mutating to avoid partial state changes on error
        let cache_size = NonZeroUsize::new(config.max_template_cache_size).ok_or(
            ConfigError::InvalidCacheSize(config.max_template_cache_size),
        )?;
        if config.max_field_count == 0 {
            return Err(ConfigError::InvalidFieldCount(0));
        }
        if config.max_template_total_size == 0 {
            return Err(ConfigError::InvalidTemplateTotalSize(0));
        }
        if config.max_records_per_flowset == 0 {
            return Err(ConfigError::InvalidRecordsPerFlowset(0));
        }
        if config.max_error_sample_size == 0 {
            return Err(ConfigError::InvalidErrorSampleSize(0));
        }
        if let Some(ref ttl) = config.ttl_config
            && ttl.duration.is_zero()
        {
            return Err(ConfigError::InvalidTtlDuration);
        }
        if let Some(ref pf) = config.pending_flows_config {
            PendingFlowCache::validate_config(pf)?;
        }

        // All validation passed — now safe to mutate
        self.set_max_template_cache_size_field(config.max_template_cache_size);
        self.set_max_field_count_field(config.max_field_count);
        self.set_max_template_total_size_field(config.max_template_total_size);
        self.set_max_error_sample_size_field(config.max_error_sample_size);
        self.set_max_records_per_flowset_field(config.max_records_per_flowset);
        self.set_ttl_config_field(config.ttl_config);
        self.set_enterprise_registry(config.enterprise_registry);
        // Safety: validate_config above already verified pending_flows_config,
        // so this call should not fail. The `?` is kept defensively.
        self.set_pending_flows_config(config.pending_flows_config)?;

        self.resize_template_caches(cache_size);
        Ok(())
    }

    /// Set the maximum template cache size
    fn set_max_template_cache_size(&mut self, size: usize) -> Result<(), ConfigError> {
        let cache_size = NonZeroUsize::new(size).ok_or(ConfigError::InvalidCacheSize(size))?;
        self.set_max_template_cache_size_field(size);
        self.resize_template_caches(cache_size);
        Ok(())
    }

    /// Set the TTL configuration for templates
    fn set_ttl_config(&mut self, ttl_config: Option<TtlConfig>) -> Result<(), ConfigError> {
        if let Some(ref ttl) = ttl_config
            && ttl.duration.is_zero()
        {
            return Err(ConfigError::InvalidTtlDuration);
        }
        self.set_ttl_config_field(ttl_config);
        Ok(())
    }

    /// Set the pending flows configuration
    ///
    /// # Errors
    /// Returns `ConfigError::InvalidPendingCacheSize` if `max_pending_flows` is 0.
    fn set_pending_flows_config(
        &mut self,
        config: Option<PendingFlowsConfig>,
    ) -> Result<(), ConfigError>;

    /// Returns whether pending flow caching is enabled.
    fn pending_flows_enabled(&self) -> bool {
        self.pending_flows().is_some()
    }

    /// Returns the total number of pending flow entries across all template IDs.
    fn pending_flow_count(&self) -> usize {
        self.pending_flows()
            .as_ref()
            .map(|cache| cache.count())
            .unwrap_or(0)
    }

    /// Clear all pending flows, recording dropped metrics.
    fn clear_pending_flows(&mut self) {
        // Count entries before clearing to record metrics.
        let count = self
            .pending_flows()
            .as_ref()
            .map(|cache| cache.count())
            .unwrap_or(0);
        if let Some(cache) = self.pending_flows_mut() {
            cache.clear();
        }
        if count > 0 {
            self.metrics_mut().record_pending_dropped_n(count as u64);
        }
    }
}
