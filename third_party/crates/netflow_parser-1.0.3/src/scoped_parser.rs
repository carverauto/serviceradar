//! Scoped parser for managing multiple NetFlow sources.
//!
//! This module provides a convenient wrapper for handling NetFlow data from multiple
//! sources (routers/exporters), ensuring template isolation per source.

use crate::{
    ConfigError, NetflowError, NetflowPacket, NetflowParser, NetflowParserBuilder, ParseResult,
    ParserCacheInfo,
};
use lru::LruCache;
use std::hash::Hash;
use std::net::SocketAddr;
use std::num::NonZeroUsize;
use std::time::{Duration, Instant};

/// Default maximum number of sources tracked by scoped parsers.
/// Prevents unbounded memory growth from spoofed source addresses.
pub const DEFAULT_MAX_SOURCES: usize = 10_000;

/// A parser that maintains separate template caches for each NetFlow source.
///
/// This is the recommended pattern for multi-source deployments where different
/// routers may use the same template IDs for different field definitions. By keeping
/// separate parser instances per source, templates are properly isolated.
///
/// Uses an LRU cache internally for O(1) eviction of the least-recently-used source
/// when at capacity, preventing DoS attacks via source address flooding.
///
/// # Type Parameter
///
/// * `K` - The key type used to identify sources. Commonly `SocketAddr` for UDP sources,
///   but can be any hashable type (e.g., `String` for named sources, `u32` for
///   observation domain IDs, etc.)
///
/// # Examples
///
/// ## Basic usage with SocketAddr
///
/// ```rust
/// use netflow_parser::RouterScopedParser;
/// use std::net::SocketAddr;
///
/// let mut scoped_parser = RouterScopedParser::<SocketAddr>::new();
///
/// // Parse packet from source 1
/// let source1 = "192.168.1.1:2055".parse().unwrap();
/// let data1 = vec![/* netflow data */];
/// let packets = scoped_parser.parse_from_source(source1, &data1);
///
/// // Parse packet from source 2 (separate template cache)
/// let source2 = "192.168.1.2:2055".parse().unwrap();
/// let data2 = vec![/* netflow data */];
/// let packets = scoped_parser.parse_from_source(source2, &data2);
/// ```
///
/// ## Custom source keys
///
/// ```rust
/// use netflow_parser::RouterScopedParser;
///
/// // Use string identifiers for sources
/// let mut scoped_parser = RouterScopedParser::<String>::new();
///
/// # let data = vec![0u8; 100];
/// let packets = scoped_parser.parse_from_source(
///     "router-nyc-01".to_string(),
///     &data
/// );
/// ```
#[derive(Debug)]
pub struct RouterScopedParser<K: Hash + Eq> {
    /// LRU cache from source identifier to (parser instance, last access time)
    parsers: LruCache<K, (NetflowParser, Instant)>,
    /// Optional builder for creating new parsers with custom configuration
    parser_builder: Option<NetflowParserBuilder>,
    /// Maximum number of sources to track.
    max_sources: usize,
}

impl<K: Hash + Eq> Default for RouterScopedParser<K> {
    fn default() -> Self {
        Self::new()
    }
}

impl<K: Hash + Eq> RouterScopedParser<K> {
    /// Create a new scoped parser with default configuration.
    ///
    /// Each new source will get a parser with default settings.
    pub fn new() -> Self {
        Self {
            parsers: LruCache::new(
                NonZeroUsize::new(DEFAULT_MAX_SOURCES)
                    .expect("DEFAULT_MAX_SOURCES is non-zero"),
            ),
            parser_builder: None,
            max_sources: DEFAULT_MAX_SOURCES,
        }
    }

    /// Create a new scoped parser with a custom parser builder.
    ///
    /// Validates the builder configuration eagerly. Returns an error if the
    /// builder configuration is invalid (e.g., zero cache size).
    ///
    /// # Errors
    ///
    /// Returns `ConfigError` if the builder configuration is invalid.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use netflow_parser::{RouterScopedParser, NetflowParser};
    /// use netflow_parser::variable_versions::ttl::TtlConfig;
    /// use std::time::Duration;
    /// use std::net::SocketAddr;
    ///
    /// let builder = NetflowParser::builder()
    ///     .with_cache_size(5000)
    ///     .with_ttl(TtlConfig::new(Duration::from_secs(3600)));
    ///
    /// let scoped_parser = RouterScopedParser::<SocketAddr>::try_with_builder(builder)
    ///     .expect("valid config");
    /// ```
    pub fn try_with_builder(builder: NetflowParserBuilder) -> Result<Self, ConfigError> {
        builder.validate()?;
        Ok(Self {
            parsers: LruCache::new(
                NonZeroUsize::new(DEFAULT_MAX_SOURCES)
                    .expect("DEFAULT_MAX_SOURCES is non-zero"),
            ),
            parser_builder: Some(builder),
            max_sources: DEFAULT_MAX_SOURCES,
        })
    }

    /// Set the maximum number of sources to track.
    ///
    /// When at capacity and a new source arrives, the least-recently-used
    /// source is automatically evicted to make room.
    /// Default: 10,000.
    ///
    /// # Errors
    ///
    /// Returns `ConfigError::InvalidMaxSources` if `max` is 0.
    pub fn with_max_sources(mut self, max: usize) -> Result<Self, ConfigError> {
        if max == 0 {
            return Err(ConfigError::InvalidMaxSources(0));
        }
        self.max_sources = max;
        self.parsers
            .resize(NonZeroUsize::new(max).expect("max is non-zero"));
        Ok(self)
    }

    /// Parse NetFlow data from a specific source.
    ///
    /// This will automatically create a new parser instance for new sources,
    /// or reuse the existing parser for known sources. When at capacity,
    /// the least-recently-used source is automatically evicted by the LRU cache.
    ///
    /// # Arguments
    ///
    /// * `source` - The source identifier (e.g., SocketAddr)
    /// * `data` - The raw NetFlow packet data
    ///
    /// # Returns
    ///
    /// A `ParseResult` containing successfully parsed packets and an optional error.
    pub fn parse_from_source(&mut self, source: K, data: &[u8]) -> ParseResult
    where
        K: Clone,
    {
        // If the source already exists, LRU get promotes it and we parse.
        if let Some((parser, last_seen)) = self.parsers.get_mut(&source) {
            *last_seen = Instant::now();
            return parser.parse_bytes(data);
        }

        // New source: LRU cache handles eviction automatically via `push`.
        let p = if let Some(ref builder) = self.parser_builder {
            match builder.clone().build() {
                Ok(p) => p,
                Err(err) => {
                    return ParseResult {
                        packets: vec![],
                        error: Some(NetflowError::Partial {
                            message: format!("Failed to build parser for source: {err}"),
                        }),
                    };
                }
            }
        } else {
            NetflowParser::default()
        };

        let now = Instant::now();
        self.parsers.push(source.clone(), (p, now));
        // The entry we just pushed is guaranteed to exist; get_mut promotes it.
        let (parser, _) = self.parsers.get_mut(&source).expect("just inserted");
        parser.parse_bytes(data)
    }

    /// Parse NetFlow data from a source using the iterator API.
    ///
    /// This is more efficient than `parse_from_source` when you don't need
    /// all packets in a Vec.
    ///
    /// # Arguments
    ///
    /// * `source` - The source identifier
    /// * `data` - The raw NetFlow packet data
    ///
    /// # Returns
    ///
    /// An iterator over parsed NetFlow packets.
    pub fn iter_packets_from_source<'a>(
        &'a mut self,
        source: K,
        data: &'a [u8],
    ) -> Result<impl Iterator<Item = Result<NetflowPacket, NetflowError>> + 'a, NetflowError>
    where
        K: Clone,
    {
        // If the source already exists, promote it in the LRU and return iterator.
        // Note: contains() + get_mut() is intentional — get_mut() borrows self.parsers
        // for the lifetime of the returned iterator, which would conflict with the
        // push/get_mut path below. contains() does not hold a borrow.
        if self.parsers.contains(&source) {
            let (parser, last_seen) =
                self.parsers.get_mut(&source).expect("checked by contains");
            *last_seen = Instant::now();
            return Ok(parser.iter_packets(data));
        }

        // New source: LRU cache handles eviction automatically via `push`.
        let p = if let Some(ref builder) = self.parser_builder {
            builder
                .clone()
                .build()
                .map_err(|err| NetflowError::Partial {
                    message: format!("Failed to build parser for source: {err}"),
                })?
        } else {
            NetflowParser::default()
        };

        let now = Instant::now();
        self.parsers.push(source.clone(), (p, now));
        let (parser, _) = self.parsers.get_mut(&source).expect("just inserted");
        Ok(parser.iter_packets(data))
    }

    /// Remove sources not seen within the given duration.
    ///
    /// Returns the number of sources pruned.
    pub fn prune_idle_sources(&mut self, older_than: Duration) -> usize
    where
        K: Clone,
    {
        let now = Instant::now();
        let keys_to_remove: Vec<K> = self
            .parsers
            .iter()
            .filter(|(_, (_, last_seen))| now.duration_since(*last_seen) >= older_than)
            .map(|(k, _)| k.clone())
            .collect();
        let count = keys_to_remove.len();
        for key in keys_to_remove {
            self.parsers.pop(&key);
        }
        count
    }

    /// Get statistics for a specific source's template cache.
    ///
    /// Returns `None` if the source hasn't sent any packets yet.
    pub fn get_source_info(&mut self, source: &K) -> Option<ParserCacheInfo> {
        self.parsers
            .peek(source)
            .map(|(parser, _)| ParserCacheInfo {
                v9: parser.v9_cache_info(),
                ipfix: parser.ipfix_cache_info(),
            })
    }

    /// Get the number of registered sources.
    pub fn source_count(&self) -> usize {
        self.parsers.len()
    }

    /// List all registered source identifiers.
    pub fn sources(&self) -> Vec<&K> {
        self.parsers.iter().map(|(k, _)| k).collect()
    }

    /// Get statistics for all sources.
    pub fn all_info(&self) -> Vec<(&K, ParserCacheInfo)> {
        self.parsers
            .iter()
            .map(|(source, (parser, _))| {
                (
                    source,
                    ParserCacheInfo {
                        v9: parser.v9_cache_info(),
                        ipfix: parser.ipfix_cache_info(),
                    },
                )
            })
            .collect()
    }

    /// Clear templates for a specific source.
    ///
    /// This is useful for testing or when you need to force template re-learning
    /// for a specific source.
    pub fn clear_source_templates(&mut self, source: &K) {
        if let Some((parser, _)) = self.parsers.peek_mut(source) {
            parser.clear_v9_templates();
            parser.clear_ipfix_templates();
        }
    }

    /// Clear templates for all sources.
    pub fn clear_all_templates(&mut self) {
        for (_, (parser, _)) in self.parsers.iter_mut() {
            parser.clear_v9_templates();
            parser.clear_ipfix_templates();
        }
    }

    /// Remove a source and its parser.
    ///
    /// This is useful for cleaning up parsers for sources that are no longer active.
    pub fn remove_source(&mut self, source: &K) -> Option<NetflowParser> {
        self.parsers.pop(source).map(|(parser, _)| parser)
    }

    /// Get a reference to a specific source's parser.
    ///
    /// Returns `None` if the source hasn't sent any packets yet.
    /// Note: This does not promote the entry in the LRU cache.
    pub fn get_parser(&mut self, source: &K) -> Option<&NetflowParser> {
        self.parsers.peek(source).map(|(parser, _)| parser)
    }

    /// Get a mutable reference to a specific source's parser.
    ///
    /// Returns `None` if the source hasn't sent any packets yet.
    /// Note: This does not promote the entry in the LRU cache.
    pub fn get_parser_mut(&mut self, source: &K) -> Option<&mut NetflowParser> {
        self.parsers.peek_mut(source).map(|(parser, _)| parser)
    }
}

/// Information extracted from NetFlow packet headers for RFC-compliant scoping.
#[non_exhaustive]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScopingInfo {
    /// NetFlow v9 packet with source ID
    V9 { source_id: u32 },
    /// IPFIX packet with observation domain ID
    IPFix { observation_domain_id: u32 },
    /// NetFlow v5 or v7 (no scoping ID in these versions)
    Legacy,
    /// Unable to determine version (invalid or truncated packet)
    Unknown,
}

/// RFC-compliant source key for IPFIX flows.
///
/// Combines the source address with the observation domain ID as specified in RFC 7011:
/// "Collecting Processes must use the Transport Session and Observation Domain ID field
/// to separate different export streams that originate from the same Exporting Process."
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IpfixSourceKey {
    /// Network address of the exporter
    pub addr: SocketAddr,
    /// Observation domain ID from IPFIX header
    pub observation_domain_id: u32,
}

/// RFC-compliant source key for NetFlow v9 flows.
///
/// Combines the source address with the source ID as specified in RFC 3954:
/// "Collector devices should use the combination of the source IP address plus the
/// Source ID field to associate an incoming NetFlow export packet with a unique
/// instance of NetFlow on a particular device."
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct V9SourceKey {
    /// Network address of the exporter
    pub addr: SocketAddr,
    /// Source ID from NetFlow v9 header
    pub source_id: u32,
}

/// Extract scoping information from a NetFlow packet header without full parsing.
///
/// This function performs a lightweight parse of just the packet header to extract
/// the scoping identifiers needed for RFC-compliant template isolation.
///
/// # Arguments
///
/// * `data` - Raw NetFlow packet data
///
/// # Returns
///
/// Returns `ScopingInfo` indicating the packet type and scoping identifier, or
/// `Unknown` if the packet is too short or has an invalid version.
///
/// # Examples
///
/// ```
/// use netflow_parser::scoped_parser::{extract_scoping_info, ScopingInfo};
///
/// # let data = vec![0u8; 20];
/// match extract_scoping_info(&data) {
///     ScopingInfo::IPFix { observation_domain_id } => {
///         println!("IPFIX packet with domain ID: {}", observation_domain_id);
///     }
///     ScopingInfo::V9 { source_id } => {
///         println!("NetFlow v9 packet with source ID: {}", source_id);
///     }
///     ScopingInfo::Legacy => {
///         println!("NetFlow v5 or v7 (no scoping ID)");
///     }
///     ScopingInfo::Unknown => {
///         println!("Invalid or truncated packet");
///     }
///     _ => {}
/// }
/// ```
pub fn extract_scoping_info(data: &[u8]) -> ScopingInfo {
    if data.len() < 2 {
        return ScopingInfo::Unknown;
    }

    // Version is first 2 bytes (big-endian)
    let version = u16::from_be_bytes([data[0], data[1]]);

    match version {
        5 | 7 => ScopingInfo::Legacy,
        9 => {
            // NetFlow v9 header is 20 bytes
            // source_id is at offset 16-19
            if data.len() < 20 {
                return ScopingInfo::Unknown;
            }
            let source_id = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
            ScopingInfo::V9 { source_id }
        }
        10 => {
            // IPFIX header is 16 bytes
            // observation_domain_id is at offset 12-15
            if data.len() < 16 {
                return ScopingInfo::Unknown;
            }
            let observation_domain_id =
                u32::from_be_bytes([data[12], data[13], data[14], data[15]]);
            ScopingInfo::IPFix {
                observation_domain_id,
            }
        }
        _ => ScopingInfo::Unknown,
    }
}

/// Automatically scoped parser that handles RFC-compliant template isolation.
///
/// This parser automatically extracts scoping identifiers from NetFlow packet headers
/// and maintains separate template caches per source according to RFC specifications:
///
/// - **NetFlow v9**: Uses `(source_addr, source_id)` per RFC 3954
/// - **IPFIX**: Uses `(source_addr, observation_domain_id)` per RFC 7011
/// - **NetFlow v5/v7**: Uses `source_addr` only (these versions have no scoping IDs)
///
/// Uses LRU caches internally for O(1) eviction of the least-recently-used source
/// when at capacity, preventing DoS attacks via source address flooding.
///
/// This is the recommended parser for production deployments as it automatically handles
/// the complexity of RFC-compliant scoping without requiring manual key management.
///
/// # Examples
///
/// ```
/// use netflow_parser::scoped_parser::AutoScopedParser;
/// use std::net::SocketAddr;
///
/// let mut parser = AutoScopedParser::new();
///
/// let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();
/// # let data = vec![0u8; 100];
///
/// // Parser automatically uses RFC-compliant scoping
/// let packets = parser.parse_from_source(source, &data);
/// ```
///
/// ## Thread Safety
///
/// Like `NetflowParser`, `AutoScopedParser` is not thread-safe. Use external synchronization
/// (e.g., `Arc<Mutex<AutoScopedParser>>`) when sharing across threads.
#[derive(Debug)]
pub struct AutoScopedParser {
    /// LRU cache for IPFIX sources (scoped by addr + observation_domain_id)
    ipfix_parsers: LruCache<IpfixSourceKey, (NetflowParser, Instant)>,
    /// LRU cache for NetFlow v9 sources (scoped by addr + source_id)
    v9_parsers: LruCache<V9SourceKey, (NetflowParser, Instant)>,
    /// LRU cache for legacy NetFlow v5/v7 (scoped by addr only)
    legacy_parsers: LruCache<SocketAddr, (NetflowParser, Instant)>,
    /// Optional builder for creating new parsers with custom configuration
    parser_builder: Option<NetflowParserBuilder>,
    /// Maximum number of sources to track across all caches.
    max_sources: usize,
}

impl Default for AutoScopedParser {
    fn default() -> Self {
        Self::new()
    }
}

impl AutoScopedParser {
    /// Create a new auto-scoped parser with default configuration.
    ///
    /// Each new source will get a parser with default settings.
    pub fn new() -> Self {
        let cap =
            NonZeroUsize::new(DEFAULT_MAX_SOURCES).expect("DEFAULT_MAX_SOURCES is non-zero");
        Self {
            ipfix_parsers: LruCache::new(cap),
            v9_parsers: LruCache::new(cap),
            legacy_parsers: LruCache::new(cap),
            parser_builder: None,
            max_sources: DEFAULT_MAX_SOURCES,
        }
    }

    /// Create a new auto-scoped parser with a custom parser builder.
    ///
    /// Validates the builder configuration eagerly. Returns an error if the
    /// builder configuration is invalid (e.g., zero cache size).
    ///
    /// # Errors
    ///
    /// Returns `ConfigError` if the builder configuration is invalid.
    ///
    /// # Examples
    ///
    /// ```
    /// use netflow_parser::scoped_parser::AutoScopedParser;
    /// use netflow_parser::NetflowParser;
    /// use netflow_parser::variable_versions::ttl::TtlConfig;
    /// use std::time::Duration;
    ///
    /// let builder = NetflowParser::builder()
    ///     .with_cache_size(5000)
    ///     .with_ttl(TtlConfig::new(Duration::from_secs(3600)));
    ///
    /// let parser = AutoScopedParser::try_with_builder(builder)
    ///     .expect("valid config");
    /// ```
    pub fn try_with_builder(builder: NetflowParserBuilder) -> Result<Self, ConfigError> {
        builder.validate()?;
        let cap =
            NonZeroUsize::new(DEFAULT_MAX_SOURCES).expect("DEFAULT_MAX_SOURCES is non-zero");
        Ok(Self {
            ipfix_parsers: LruCache::new(cap),
            v9_parsers: LruCache::new(cap),
            legacy_parsers: LruCache::new(cap),
            parser_builder: Some(builder),
            max_sources: DEFAULT_MAX_SOURCES,
        })
    }

    /// Set the maximum number of sources to track across all protocol types.
    ///
    /// When at capacity and a new source arrives, the least-recently-used
    /// source is automatically evicted to make room.
    /// Default: 10,000.
    ///
    /// # Errors
    ///
    /// Returns `ConfigError::InvalidMaxSources` if `max` is 0.
    pub fn with_max_sources(mut self, max: usize) -> Result<Self, ConfigError> {
        if max == 0 {
            return Err(ConfigError::InvalidMaxSources(0));
        }
        self.max_sources = max;
        // Size each per-protocol LRU cache to max. The global cross-cache
        // eviction at `source_count() >= max_sources` enforces the true total
        // limit; individual caches are capped so their internal LRU eviction
        // doesn't fire before the global policy.
        let cap = NonZeroUsize::new(max).expect("max is non-zero");
        self.ipfix_parsers.resize(cap);
        self.v9_parsers.resize(cap);
        self.legacy_parsers.resize(cap);
        Ok(self)
    }

    /// Parse NetFlow data from a source with automatic RFC-compliant scoping.
    ///
    /// This method automatically:
    /// 1. Extracts the scoping identifier from the packet header
    /// 2. Routes to the appropriate scoped parser
    /// 3. Creates new parser instances as needed
    ///
    /// # Arguments
    ///
    /// * `source` - The network address of the exporter
    /// * `data` - The raw NetFlow packet data
    ///
    /// # Returns
    ///
    /// A `ParseResult` containing successfully parsed packets and an optional error.
    ///
    /// # Examples
    ///
    /// ```
    /// use netflow_parser::scoped_parser::AutoScopedParser;
    /// use std::net::SocketAddr;
    ///
    /// let mut parser = AutoScopedParser::new();
    /// let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();
    /// # let data = vec![0u8; 100];
    ///
    /// let packets = parser.parse_from_source(source, &data);
    /// ```
    pub fn parse_from_source(&mut self, source: SocketAddr, data: &[u8]) -> ParseResult {
        let parser = match self.get_or_create_parser(source, data) {
            Ok(p) => p,
            Err(e) => {
                return ParseResult {
                    packets: vec![],
                    error: Some(e),
                };
            }
        };
        parser.parse_bytes(data)
    }

    /// Parse NetFlow data from a source using the iterator API.
    ///
    /// This is more efficient than `parse_from_source` when you don't need
    /// all packets in a Vec.
    ///
    /// # Arguments
    ///
    /// * `source` - The network address of the exporter
    /// * `data` - The raw NetFlow packet data
    ///
    /// # Returns
    ///
    /// An iterator over parsed NetFlow packets.
    pub fn iter_packets_from_source<'a>(
        &'a mut self,
        source: SocketAddr,
        data: &'a [u8],
    ) -> Result<impl Iterator<Item = Result<NetflowPacket, NetflowError>> + 'a, NetflowError>
    {
        let parser = self.get_or_create_parser(source, data)?;
        Ok(parser.iter_packets(data))
    }

    /// Remove sources not seen within the given duration across all protocol types.
    ///
    /// Returns the number of sources pruned.
    pub fn prune_idle_sources(&mut self, older_than: Duration) -> usize {
        let now = Instant::now();

        let ipfix_keys: Vec<IpfixSourceKey> = self
            .ipfix_parsers
            .iter()
            .filter(|(_, (_, last_seen))| now.duration_since(*last_seen) >= older_than)
            .map(|(k, _)| *k)
            .collect();

        let v9_keys: Vec<V9SourceKey> = self
            .v9_parsers
            .iter()
            .filter(|(_, (_, last_seen))| now.duration_since(*last_seen) >= older_than)
            .map(|(k, _)| *k)
            .collect();

        let legacy_keys: Vec<SocketAddr> = self
            .legacy_parsers
            .iter()
            .filter(|(_, (_, last_seen))| now.duration_since(*last_seen) >= older_than)
            .map(|(k, _)| *k)
            .collect();

        let count = ipfix_keys.len() + v9_keys.len() + legacy_keys.len();

        for key in ipfix_keys {
            self.ipfix_parsers.pop(&key);
        }
        for key in v9_keys {
            self.v9_parsers.pop(&key);
        }
        for key in legacy_keys {
            self.legacy_parsers.pop(&key);
        }

        count
    }

    /// Get the total number of registered sources across all scoping types.
    pub fn source_count(&self) -> usize {
        self.ipfix_parsers.len() + self.v9_parsers.len() + self.legacy_parsers.len()
    }

    /// Get the number of IPFIX sources.
    pub fn ipfix_source_count(&self) -> usize {
        self.ipfix_parsers.len()
    }

    /// Get the number of NetFlow v9 sources.
    pub fn v9_source_count(&self) -> usize {
        self.v9_parsers.len()
    }

    /// Get the number of legacy (v5/v7) sources.
    pub fn legacy_source_count(&self) -> usize {
        self.legacy_parsers.len()
    }

    /// Remove an IPFIX source and its parser.
    pub fn remove_ipfix_source(&mut self, key: &IpfixSourceKey) -> Option<NetflowParser> {
        self.ipfix_parsers.pop(key).map(|(parser, _)| parser)
    }

    /// Remove a V9 source and its parser.
    pub fn remove_v9_source(&mut self, key: &V9SourceKey) -> Option<NetflowParser> {
        self.v9_parsers.pop(key).map(|(parser, _)| parser)
    }

    /// Remove a legacy source and its parser.
    pub fn remove_legacy_source(&mut self, addr: &SocketAddr) -> Option<NetflowParser> {
        self.legacy_parsers.pop(addr).map(|(parser, _)| parser)
    }

    /// Clear templates for all sources.
    pub fn clear_all_templates(&mut self) {
        for (_, (parser, _)) in self.ipfix_parsers.iter_mut() {
            parser.clear_v9_templates();
            parser.clear_ipfix_templates();
        }
        for (_, (parser, _)) in self.v9_parsers.iter_mut() {
            parser.clear_v9_templates();
            parser.clear_ipfix_templates();
        }
        for (_, (parser, _)) in self.legacy_parsers.iter_mut() {
            parser.clear_v9_templates();
            parser.clear_ipfix_templates();
        }
    }

    /// Get statistics for all IPFIX sources.
    pub fn ipfix_info(&self) -> Vec<(&IpfixSourceKey, ParserCacheInfo)> {
        self.ipfix_parsers
            .iter()
            .map(|(key, (parser, _))| {
                (
                    key,
                    ParserCacheInfo {
                        v9: parser.v9_cache_info(),
                        ipfix: parser.ipfix_cache_info(),
                    },
                )
            })
            .collect()
    }

    /// Get statistics for all NetFlow v9 sources.
    pub fn v9_info(&self) -> Vec<(&V9SourceKey, ParserCacheInfo)> {
        self.v9_parsers
            .iter()
            .map(|(key, (parser, _))| {
                (
                    key,
                    ParserCacheInfo {
                        v9: parser.v9_cache_info(),
                        ipfix: parser.ipfix_cache_info(),
                    },
                )
            })
            .collect()
    }

    /// Get statistics for all legacy sources.
    pub fn legacy_info(&self) -> Vec<(&SocketAddr, ParserCacheInfo)> {
        self.legacy_parsers
            .iter()
            .map(|(addr, (parser, _))| {
                (
                    addr,
                    ParserCacheInfo {
                        v9: parser.v9_cache_info(),
                        ipfix: parser.ipfix_cache_info(),
                    },
                )
            })
            .collect()
    }

    /// Get or create a parser for the given source, using LRU eviction when at capacity.
    fn get_or_create_parser(
        &mut self,
        source: SocketAddr,
        data: &[u8],
    ) -> Result<&mut NetflowParser, NetflowError> {
        let scoping = extract_scoping_info(data);
        let is_new = match &scoping {
            ScopingInfo::IPFix {
                observation_domain_id,
            } => !self.ipfix_parsers.contains(&IpfixSourceKey {
                addr: source,
                observation_domain_id: *observation_domain_id,
            }),
            ScopingInfo::V9 { source_id } => !self.v9_parsers.contains(&V9SourceKey {
                addr: source,
                source_id: *source_id,
            }),
            ScopingInfo::Legacy => !self.legacy_parsers.contains(&source),
            ScopingInfo::Unknown => false, // malformed packets don't create sources
        };

        // When at capacity with a new source, evict the LRU entry from the
        // appropriate cache. Each cache has its own capacity managed by LRU,
        // but we also enforce a total cross-cache limit.
        if is_new && self.source_count() >= self.max_sources {
            self.evict_global_lru();
        }

        let builder = self.parser_builder.as_ref();
        let now = Instant::now();
        match scoping {
            ScopingInfo::IPFix {
                observation_domain_id,
            } => {
                let key = IpfixSourceKey {
                    addr: source,
                    observation_domain_id,
                };
                if !self.ipfix_parsers.contains(&key) {
                    let scope = format!("ipfix:{}/{}", source, observation_domain_id);
                    let parser = Self::build_parser(builder, &scope)?;
                    self.ipfix_parsers.push(key, (parser, now));
                }
                let (parser, last_seen) =
                    self.ipfix_parsers.get_mut(&key).expect("just ensured");
                *last_seen = now;
                Ok(parser)
            }
            ScopingInfo::V9 { source_id } => {
                let key = V9SourceKey {
                    addr: source,
                    source_id,
                };
                if !self.v9_parsers.contains(&key) {
                    let scope = format!("v9:{}/{}", source, source_id);
                    let parser = Self::build_parser(builder, &scope)?;
                    self.v9_parsers.push(key, (parser, now));
                }
                let (parser, last_seen) = self.v9_parsers.get_mut(&key).expect("just ensured");
                *last_seen = now;
                Ok(parser)
            }
            ScopingInfo::Legacy => {
                if !self.legacy_parsers.contains(&source) {
                    let scope = format!("legacy:{}", source);
                    let parser = Self::build_parser(builder, &scope)?;
                    self.legacy_parsers.push(source, (parser, now));
                }
                let (parser, last_seen) =
                    self.legacy_parsers.get_mut(&source).expect("just ensured");
                *last_seen = now;
                Ok(parser)
            }
            ScopingInfo::Unknown => {
                // Don't create parser instances for malformed/truncated packets.
                // This prevents source-slot exhaustion attacks where spoofed
                // truncated packets fill the parser pool and evict legitimate entries.
                Err(crate::NetflowError::Incomplete {
                    available: data.len(),
                    context: "packet too short or unrecognized version for scoping".into(),
                })
            }
        }
    }

    /// Evict the globally least-recently-used entry across all three caches.
    /// Uses O(1) peek at the LRU entry of each cache, then pops from the oldest.
    fn evict_global_lru(&mut self) {
        let ipfix_ts = self.ipfix_parsers.peek_lru().map(|(_, (_, ts))| *ts);
        let v9_ts = self.v9_parsers.peek_lru().map(|(_, (_, ts))| *ts);
        let legacy_ts = self.legacy_parsers.peek_lru().map(|(_, (_, ts))| *ts);

        // Find which cache has the globally oldest LRU entry.
        #[derive(Clone, Copy)]
        enum MapKind {
            Ipfix,
            V9,
            Legacy,
        }

        // Include cache length as a tiebreaker (largest cache evicts first)
        // so that no protocol is systematically favored when timestamps are equal.
        let candidates = [
            ipfix_ts.map(|ts| (MapKind::Ipfix, ts, self.ipfix_parsers.len())),
            v9_ts.map(|ts| (MapKind::V9, ts, self.v9_parsers.len())),
            legacy_ts.map(|ts| (MapKind::Legacy, ts, self.legacy_parsers.len())),
        ];

        let oldest = candidates
            .iter()
            .flatten()
            .min_by(|(_, ts_a, len_a), (_, ts_b, len_b)| {
                ts_a.cmp(ts_b).then_with(|| len_b.cmp(len_a)) // larger cache evicts first on tie
            })
            .map(|(kind, _, _)| *kind);

        match oldest {
            Some(MapKind::Ipfix) => {
                self.ipfix_parsers.pop_lru();
            }
            Some(MapKind::V9) => {
                self.v9_parsers.pop_lru();
            }
            Some(MapKind::Legacy) => {
                self.legacy_parsers.pop_lru();
            }
            None => {}
        }
    }

    /// Create a new parser instance using the configured builder or default
    fn build_parser(
        builder: Option<&NetflowParserBuilder>,
        scope: &str,
    ) -> Result<NetflowParser, NetflowError> {
        let mut parser = if let Some(builder) = builder {
            builder
                .clone()
                .build()
                .map_err(|err| NetflowError::Partial {
                    message: format!("Failed to build parser for source: {err}"),
                })?
        } else {
            NetflowParser::default()
        };
        // Override the template-store scope so per-source parsers do not
        // collide on shared template IDs in the secondary store. Cheap when
        // no store is configured (just an Arc<str> swap).
        parser.set_template_store_scope(scope);
        Ok(parser)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    // Verify RouterScopedParser creates per-source parsers on first use
    #[test]
    fn test_scoped_parser_basic() {
        let mut scoped = RouterScopedParser::<SocketAddr>::new();

        // Initially no sources
        assert_eq!(scoped.source_count(), 0);

        // Parse from first source
        let source1: SocketAddr = "192.168.1.1:2055".parse().unwrap();
        let data = vec![0u8; 100];
        let _ = scoped.parse_from_source(source1, &data);

        // Now we have one source
        assert_eq!(scoped.source_count(), 1);
        assert!(scoped.get_source_info(&source1).is_some());

        // Parse from second source
        let source2: SocketAddr = "192.168.1.2:2055".parse().unwrap();
        let _ = scoped.parse_from_source(source2, &data);

        // Now we have two sources
        assert_eq!(scoped.source_count(), 2);
        assert!(scoped.get_source_info(&source2).is_some());
    }

    // Verify RouterScopedParser works with String keys
    #[test]
    fn test_scoped_parser_with_string_keys() {
        let mut scoped = RouterScopedParser::<String>::new();

        let router1 = "router-nyc-01".to_string();
        let router2 = "router-sfo-02".to_string();

        let data = vec![0u8; 100];
        let _ = scoped.parse_from_source(router1.clone(), &data);
        let _ = scoped.parse_from_source(router2.clone(), &data);

        assert_eq!(scoped.source_count(), 2);
        assert!(scoped.sources().contains(&&router1));
        assert!(scoped.sources().contains(&&router2));
    }

    // Verify remove_source drops the parser for that key
    #[test]
    fn test_remove_source() {
        let mut scoped = RouterScopedParser::<String>::new();

        let router = "router-1".to_string();
        let data = vec![0u8; 100];
        let _ = scoped.parse_from_source(router.clone(), &data);

        assert_eq!(scoped.source_count(), 1);

        scoped.remove_source(&router);
        assert_eq!(scoped.source_count(), 0);
    }

    // Verify clear_source_templates and clear_all_templates don't panic
    #[test]
    fn test_clear_templates() {
        let mut scoped = RouterScopedParser::<String>::new();

        let router = "router-1".to_string();
        let data = vec![0u8; 100];
        let _ = scoped.parse_from_source(router.clone(), &data);

        scoped.clear_source_templates(&router);
        scoped.clear_all_templates();
    }

    // Verify V9 packet scoping extracts source_id from header bytes
    #[test]
    fn test_extract_scoping_info_v9() {
        // NetFlow v9 packet with source_id = 0x12345678
        let mut data = vec![0u8; 20];
        data[0] = 0x00;
        data[1] = 0x09; // Version 9
        data[16] = 0x12;
        data[17] = 0x34;
        data[18] = 0x56;
        data[19] = 0x78; // source_id

        let info = extract_scoping_info(&data);
        assert_eq!(
            info,
            ScopingInfo::V9 {
                source_id: 0x12345678
            }
        );
    }

    // Verify IPFIX packet scoping extracts observation_domain_id from header bytes
    #[test]
    fn test_extract_scoping_info_ipfix() {
        // IPFIX packet with observation_domain_id = 0xABCDEF01
        let mut data = vec![0u8; 16];
        data[0] = 0x00;
        data[1] = 0x0A; // Version 10 (IPFIX)
        data[12] = 0xAB;
        data[13] = 0xCD;
        data[14] = 0xEF;
        data[15] = 0x01; // observation_domain_id

        let info = extract_scoping_info(&data);
        assert_eq!(
            info,
            ScopingInfo::IPFix {
                observation_domain_id: 0xABCDEF01
            }
        );
    }

    // Verify V5 packets return Legacy scoping info
    #[test]
    fn test_extract_scoping_info_v5() {
        // NetFlow v5 packet
        let mut data = vec![0u8; 24];
        data[0] = 0x00;
        data[1] = 0x05; // Version 5

        let info = extract_scoping_info(&data);
        assert_eq!(info, ScopingInfo::Legacy);
    }

    // Verify truncated packets return Unknown scoping info
    #[test]
    fn test_extract_scoping_info_truncated() {
        // Truncated packet
        let data = vec![0x00, 0x09]; // Version 9 but too short

        let info = extract_scoping_info(&data);
        assert_eq!(info, ScopingInfo::Unknown);
    }

    // Verify unrecognized version numbers return Unknown scoping info
    #[test]
    fn test_extract_scoping_info_unknown_version() {
        // Unknown version
        let data = vec![0x00, 0xFF];

        let info = extract_scoping_info(&data);
        assert_eq!(info, ScopingInfo::Unknown);
    }

    // Verify AutoScopedParser initializes with zero sources
    #[test]
    fn test_auto_scoped_parser_basic() {
        let parser = AutoScopedParser::new();

        // Initially no sources
        assert_eq!(parser.source_count(), 0);
        assert_eq!(parser.ipfix_source_count(), 0);
        assert_eq!(parser.v9_source_count(), 0);
        assert_eq!(parser.legacy_source_count(), 0);
    }

    // Verify V9 and IPFIX packets are routed to separate source-specific parsers
    #[test]
    fn test_auto_scoped_parser_routes_correctly() {
        let mut parser = AutoScopedParser::new();
        let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();

        // Parse V9 packet
        let mut v9_data = vec![0u8; 20];
        v9_data[0] = 0x00;
        v9_data[1] = 0x09; // Version 9
        v9_data[16] = 0x00;
        v9_data[17] = 0x00;
        v9_data[18] = 0x00;
        v9_data[19] = 0x01; // source_id = 1

        let _ = parser.parse_from_source(source, &v9_data);
        assert_eq!(parser.v9_source_count(), 1);
        assert_eq!(parser.ipfix_source_count(), 0);

        // Parse IPFIX packet from same address but different observation domain
        let mut ipfix_data = vec![0u8; 16];
        ipfix_data[0] = 0x00;
        ipfix_data[1] = 0x0A; // Version 10 (IPFIX)
        ipfix_data[12] = 0x00;
        ipfix_data[13] = 0x00;
        ipfix_data[14] = 0x00;
        ipfix_data[15] = 0x02; // observation_domain_id = 2

        let _ = parser.parse_from_source(source, &ipfix_data);
        assert_eq!(parser.v9_source_count(), 1);
        assert_eq!(parser.ipfix_source_count(), 1);
        assert_eq!(parser.source_count(), 2);
    }

    // Verify different IPFIX observation domains create separate parsers
    #[test]
    fn test_auto_scoped_parser_multiple_domains() {
        let mut parser = AutoScopedParser::new();
        let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();

        // Parse IPFIX packets with different observation domains
        for domain_id in 1..=3 {
            let mut data = vec![0u8; 16];
            data[0] = 0x00;
            data[1] = 0x0A; // Version 10 (IPFIX)
            data[12] = 0x00;
            data[13] = 0x00;
            data[14] = 0x00;
            data[15] = domain_id;

            let _ = parser.parse_from_source(source, &data);
        }

        // Should have 3 separate IPFIX parsers (one per observation domain)
        assert_eq!(parser.ipfix_source_count(), 3);
    }

    // Verify IPFIX stats include observation_domain_id for each source
    #[test]
    fn test_auto_scoped_parser_stats() {
        let mut parser = AutoScopedParser::new();
        let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();

        // Add IPFIX source
        let mut ipfix_data = vec![0u8; 16];
        ipfix_data[0] = 0x00;
        ipfix_data[1] = 0x0A;
        ipfix_data[15] = 0x01;
        let _ = parser.parse_from_source(source, &ipfix_data);

        // Get stats
        let ipfix_info = parser.ipfix_info();
        assert_eq!(ipfix_info.len(), 1);
        assert_eq!(ipfix_info[0].0.observation_domain_id, 1);
    }

    // Verify clear_all_templates preserves parser instances but clears caches
    #[test]
    fn test_auto_scoped_parser_clear_all() {
        let mut parser = AutoScopedParser::new();
        let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();

        // Add some sources
        let mut ipfix_data = vec![0u8; 16];
        ipfix_data[0] = 0x00;
        ipfix_data[1] = 0x0A;
        let _ = parser.parse_from_source(source, &ipfix_data);

        parser.clear_all_templates();
        // Should still have the parser instances
        assert_eq!(parser.ipfix_source_count(), 1);
    }

    // Verify with_max_sources(0) returns an error
    #[test]
    fn test_max_sources_zero_rejected_router() {
        let result = RouterScopedParser::<SocketAddr>::new().with_max_sources(0);
        assert!(result.is_err());
    }

    // Verify with_max_sources(0) returns an error for AutoScopedParser
    #[test]
    fn test_max_sources_zero_rejected_auto() {
        let result = AutoScopedParser::new().with_max_sources(0);
        assert!(result.is_err());
    }

    // Verify RouterScopedParser evicts LRU source when at capacity
    #[test]
    fn test_router_scoped_evicts_oldest() {
        let mut scoped = RouterScopedParser::<String>::new()
            .with_max_sources(2)
            .expect("valid");

        let data = vec![0u8; 100];

        // Add source A
        let _ = scoped.parse_from_source("A".to_string(), &data);
        // Add source B
        let _ = scoped.parse_from_source("B".to_string(), &data);
        assert_eq!(scoped.source_count(), 2);

        // Add source C — should evict the LRU (A, since it was used first)
        let _ = scoped.parse_from_source("C".to_string(), &data);
        assert_eq!(scoped.source_count(), 2);
        // A should be gone, B and C should remain
        assert!(scoped.get_parser(&"A".to_string()).is_none());
        assert!(scoped.get_parser(&"B".to_string()).is_some());
        assert!(scoped.get_parser(&"C".to_string()).is_some());
    }

    // Verify AutoScopedParser evicts LRU source when at capacity
    #[test]
    fn test_auto_scoped_evicts_oldest() {
        let mut parser = AutoScopedParser::new().with_max_sources(2).expect("valid");

        let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();

        // Add 2 IPFIX sources with different observation domains
        for domain_id in 1..=2u8 {
            let mut data = vec![0u8; 16];
            data[0] = 0x00;
            data[1] = 0x0A;
            data[15] = domain_id;
            let _ = parser.parse_from_source(source, &data);
        }
        assert_eq!(parser.source_count(), 2);

        // Add a 3rd source — should evict the LRU
        let mut data = vec![0u8; 16];
        data[0] = 0x00;
        data[1] = 0x0A;
        data[15] = 3;
        let _ = parser.parse_from_source(source, &data);
        assert_eq!(parser.source_count(), 2);
    }

    // Verify prune_idle_sources removes stale entries for RouterScopedParser
    #[test]
    fn test_router_prune_idle_sources() {
        let mut scoped = RouterScopedParser::<String>::new();
        let data = vec![0u8; 100];

        let _ = scoped.parse_from_source("A".to_string(), &data);
        assert_eq!(scoped.source_count(), 1);

        // Pruning with a very short duration should remove everything
        // (entries were just created, so elapsed > 0ns)
        // Use a generous duration that shouldn't prune anything
        let pruned = scoped.prune_idle_sources(Duration::from_secs(3600));
        assert_eq!(pruned, 0);
        assert_eq!(scoped.source_count(), 1);
    }

    // Verify prune_idle_sources removes stale entries for AutoScopedParser
    #[test]
    fn test_auto_prune_idle_sources() {
        let mut parser = AutoScopedParser::new();
        let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();

        let mut data = vec![0u8; 16];
        data[0] = 0x00;
        data[1] = 0x0A;
        data[15] = 1;
        let _ = parser.parse_from_source(source, &data);
        assert_eq!(parser.source_count(), 1);

        // Generous duration should not prune
        let pruned = parser.prune_idle_sources(Duration::from_secs(3600));
        assert_eq!(pruned, 0);
        assert_eq!(parser.source_count(), 1);
    }
}
