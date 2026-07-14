use std::net::IpAddr;

use serde::Serialize;

use crate::NetflowPacket;
use crate::protocol::ProtocolTypes;
use crate::static_versions::{v5::V5, v7::V7};
use crate::variable_versions::field_value::FieldValue;
use crate::variable_versions::ipfix::lookup::{IANAIPFixField, IPFixField};
use crate::variable_versions::v9::lookup::V9Field;
use crate::variable_versions::{
    ipfix::{FlowSetBody as IPFixFlowSetBody, IPFix},
    v9::{FlowSetBody as V9FlowSetBody, V9},
};

#[derive(Debug)]
pub enum NetflowCommonError {
    UnknownVersion(u16),
}

impl std::fmt::Display for NetflowCommonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NetflowCommonError::UnknownVersion(version) => {
                write!(f, "unknown or unsupported NetFlow version: {}", version)
            }
        }
    }
}

impl std::error::Error for NetflowCommonError {}

/// Generic configuration for mapping fields to NetflowCommonFlowSet fields.
/// Each field can have a primary and optional fallback field type.
#[derive(Debug, Clone)]
pub struct FieldMapping<T> {
    /// Primary field to search for
    pub primary: T,
    /// Optional fallback field if primary is not found
    pub fallback: Option<T>,
}

impl<T> FieldMapping<T> {
    /// Create a new field mapping with only a primary field
    pub fn new(primary: T) -> Self {
        Self {
            primary,
            fallback: None,
        }
    }

    /// Create a new field mapping with a primary and fallback field
    pub fn with_fallback(primary: T, fallback: T) -> Self {
        Self {
            primary,
            fallback: Some(fallback),
        }
    }
}

/// Type alias for V9 field mapping configuration
pub type V9FieldMapping = FieldMapping<V9Field>;

/// Type alias for IPFix field mapping configuration
pub type IPFixFieldMapping = FieldMapping<IPFixField>;

/// Configuration for V9 field mappings used when converting V9 to NetflowCommon.
///
/// This allows customization of which V9 fields map to which NetflowCommonFlowSet fields.
/// By default, standard IANA field mappings are used.
///
/// # Example
///
/// ```rust
/// use netflow_parser::netflow_common::V9FieldMappingConfig;
/// use netflow_parser::variable_versions::v9::lookup::V9Field;
///
/// // Use default mappings
/// let config = V9FieldMappingConfig::default();
///
/// // Or customize specific fields
/// let mut config = V9FieldMappingConfig::default();
/// config.src_addr.primary = V9Field::Ipv6SrcAddr;  // Prefer IPv6
/// config.src_addr.fallback = Some(V9Field::Ipv4SrcAddr);  // Fall back to IPv4
/// ```
#[derive(Debug, Clone)]
pub struct V9FieldMappingConfig {
    /// Mapping for source address field
    pub src_addr: V9FieldMapping,
    /// Mapping for destination address field
    pub dst_addr: V9FieldMapping,
    /// Mapping for source port field
    pub src_port: V9FieldMapping,
    /// Mapping for destination port field
    pub dst_port: V9FieldMapping,
    /// Mapping for protocol field
    pub protocol: V9FieldMapping,
    /// Mapping for first seen timestamp field
    pub first_seen: V9FieldMapping,
    /// Mapping for last seen timestamp field
    pub last_seen: V9FieldMapping,
    /// Mapping for source MAC address field
    pub src_mac: V9FieldMapping,
    /// Mapping for destination MAC address field
    pub dst_mac: V9FieldMapping,
}

impl Default for V9FieldMappingConfig {
    fn default() -> Self {
        Self {
            src_addr: V9FieldMapping::with_fallback(V9Field::Ipv4SrcAddr, V9Field::Ipv6SrcAddr),
            dst_addr: V9FieldMapping::with_fallback(V9Field::Ipv4DstAddr, V9Field::Ipv6DstAddr),
            src_port: V9FieldMapping::new(V9Field::L4SrcPort),
            dst_port: V9FieldMapping::new(V9Field::L4DstPort),
            protocol: V9FieldMapping::new(V9Field::Protocol),
            first_seen: V9FieldMapping::new(V9Field::FirstSwitched),
            last_seen: V9FieldMapping::new(V9Field::LastSwitched),
            src_mac: V9FieldMapping::new(V9Field::InSrcMac),
            dst_mac: V9FieldMapping::new(V9Field::InDstMac),
        }
    }
}

/// Configuration for IPFIX field mappings used when converting IPFIX to NetflowCommon.
///
/// This allows customization of which IPFIX fields map to which NetflowCommonFlowSet fields.
/// By default, standard IANA field mappings are used.
///
/// # Example
///
/// ```rust
/// use netflow_parser::netflow_common::IPFixFieldMappingConfig;
/// use netflow_parser::variable_versions::ipfix::lookup::{IPFixField, IANAIPFixField};
///
/// // Use default mappings
/// let config = IPFixFieldMappingConfig::default();
///
/// // Or customize specific fields
/// let mut config = IPFixFieldMappingConfig::default();
/// config.src_addr.primary = IPFixField::IANA(IANAIPFixField::SourceIpv6address);  // Prefer IPv6
/// config.src_addr.fallback = Some(IPFixField::IANA(IANAIPFixField::SourceIpv4address));  // Fall back to IPv4
/// ```
#[derive(Debug, Clone)]
pub struct IPFixFieldMappingConfig {
    /// Mapping for source address field
    pub src_addr: IPFixFieldMapping,
    /// Mapping for destination address field
    pub dst_addr: IPFixFieldMapping,
    /// Mapping for source port field
    pub src_port: IPFixFieldMapping,
    /// Mapping for destination port field
    pub dst_port: IPFixFieldMapping,
    /// Mapping for protocol field
    pub protocol: IPFixFieldMapping,
    /// Mapping for first seen timestamp field
    pub first_seen: IPFixFieldMapping,
    /// Mapping for last seen timestamp field
    pub last_seen: IPFixFieldMapping,
    /// Mapping for source MAC address field
    pub src_mac: IPFixFieldMapping,
    /// Mapping for destination MAC address field
    pub dst_mac: IPFixFieldMapping,
}

impl Default for IPFixFieldMappingConfig {
    fn default() -> Self {
        Self {
            src_addr: IPFixFieldMapping::with_fallback(
                IPFixField::IANA(IANAIPFixField::SourceIpv4address),
                IPFixField::IANA(IANAIPFixField::SourceIpv6address),
            ),
            dst_addr: IPFixFieldMapping::with_fallback(
                IPFixField::IANA(IANAIPFixField::DestinationIpv4address),
                IPFixField::IANA(IANAIPFixField::DestinationIpv6address),
            ),
            src_port: IPFixFieldMapping::new(IPFixField::IANA(
                IANAIPFixField::SourceTransportPort,
            )),
            dst_port: IPFixFieldMapping::new(IPFixField::IANA(
                IANAIPFixField::DestinationTransportPort,
            )),
            protocol: IPFixFieldMapping::new(IPFixField::IANA(
                IANAIPFixField::ProtocolIdentifier,
            )),
            first_seen: IPFixFieldMapping::new(IPFixField::IANA(
                IANAIPFixField::FlowStartSysUpTime,
            )),
            last_seen: IPFixFieldMapping::new(IPFixField::IANA(
                IANAIPFixField::FlowEndSysUpTime,
            )),
            src_mac: IPFixFieldMapping::new(IPFixField::IANA(IANAIPFixField::SourceMacaddress)),
            dst_mac: IPFixFieldMapping::new(IPFixField::IANA(
                IANAIPFixField::DestinationMacaddress,
            )),
        }
    }
}

#[derive(Debug, Default, Clone, Serialize)]
/// Common structure for Netflow
pub struct NetflowCommon {
    pub version: u16,
    pub timestamp: u32,
    pub flowsets: Vec<NetflowCommonFlowSet>,
}

impl TryFrom<&NetflowPacket> for NetflowCommon {
    type Error = NetflowCommonError;

    fn try_from(value: &NetflowPacket) -> Result<Self, NetflowCommonError> {
        match value {
            NetflowPacket::V5(v5) => Ok(v5.into()),
            NetflowPacket::V7(v7) => Ok(v7.into()),
            NetflowPacket::V9(v9) => Ok(v9.into()),
            NetflowPacket::IPFix(ipfix) => Ok(ipfix.into()),
        }
    }
}

#[derive(Debug, Default, Clone, Serialize)]
/// Common flow set structure for Netflow
pub struct NetflowCommonFlowSet {
    /// Source IP address
    pub src_addr: Option<IpAddr>,
    /// Destination IP address
    pub dst_addr: Option<IpAddr>,
    /// TCP/UDP source port number or equivalent
    pub src_port: Option<u16>,
    /// TCP/UDP destination port number or equivalent
    pub dst_port: Option<u16>,
    /// Number of IP protocol type (for example, TCP = 6; UDP = 17)
    pub protocol_number: Option<u8>,
    /// IP protocol type itself
    pub protocol_type: Option<ProtocolTypes>,
    /// Timestamp for when the flow was first seen.
    /// For V5/V7: sysUpTime-relative value in milliseconds (i.e., milliseconds since
    /// the router booted, as reported in the `first` field).
    /// For V9/IPFIX: depends on the configured field mapping (e.g., FirstSwitched is
    /// sysUpTime-relative milliseconds; flowStartMilliseconds is absolute epoch millis).
    pub first_seen: Option<u64>,
    /// Timestamp for when the flow was last seen.
    /// For V5/V7: sysUpTime-relative value in milliseconds (i.e., milliseconds since
    /// the router booted, as reported in the `last` field).
    /// For V9/IPFIX: depends on the configured field mapping (e.g., LastSwitched is
    /// sysUpTime-relative milliseconds; flowEndMilliseconds is absolute epoch millis).
    pub last_seen: Option<u64>,
    /// Source MAC address
    pub src_mac: Option<String>,
    /// Destination MAC address
    pub dst_mac: Option<String>,
}

impl From<&V5> for NetflowCommon {
    fn from(value: &V5) -> Self {
        // Convert V5 to NetflowCommon
        NetflowCommon {
            version: value.header.version,
            timestamp: value.header.sys_up_time,
            flowsets: value
                .flowsets
                .iter()
                .map(|set| NetflowCommonFlowSet {
                    src_addr: Some(set.src_addr.into()),
                    dst_addr: Some(set.dst_addr.into()),
                    src_port: Some(set.src_port),
                    dst_port: Some(set.dst_port),
                    protocol_number: Some(set.protocol_number),
                    protocol_type: Some(set.protocol_type),
                    first_seen: Some(u64::from(set.first)),
                    last_seen: Some(u64::from(set.last)),
                    src_mac: None,
                    dst_mac: None,
                })
                .collect(),
        }
    }
}

impl From<&V7> for NetflowCommon {
    fn from(value: &V7) -> Self {
        // Convert V7 to NetflowCommon
        NetflowCommon {
            version: value.header.version,
            timestamp: value.header.sys_up_time,
            flowsets: value
                .flowsets
                .iter()
                .map(|set| NetflowCommonFlowSet {
                    src_addr: Some(set.src_addr.into()),
                    dst_addr: Some(set.dst_addr.into()),
                    src_port: Some(set.src_port),
                    dst_port: Some(set.dst_port),
                    protocol_number: Some(set.protocol_number),
                    protocol_type: Some(set.protocol_type),
                    first_seen: Some(u64::from(set.first)),
                    last_seen: Some(u64::from(set.last)),
                    src_mac: None,
                    dst_mac: None,
                })
                .collect(),
        }
    }
}

/// Unified field cache for collecting common flow fields in a single pass.
/// Used by both V9 and IPFIX default and config-based conversions.
#[derive(Copy, Clone, Default)]
struct FieldCache<'a> {
    src_addr: Option<&'a FieldValue>,
    dst_addr: Option<&'a FieldValue>,
    src_port: Option<&'a FieldValue>,
    dst_port: Option<&'a FieldValue>,
    protocol: Option<&'a FieldValue>,
    first_seen: Option<&'a FieldValue>,
    last_seen: Option<&'a FieldValue>,
    src_mac: Option<&'a FieldValue>,
    dst_mac: Option<&'a FieldValue>,
}

impl<'a> FieldCache<'a> {
    fn to_common_flowset(self) -> NetflowCommonFlowSet {
        NetflowCommonFlowSet {
            src_addr: self.src_addr.and_then(|v| v.try_into().ok()),
            dst_addr: self.dst_addr.and_then(|v| v.try_into().ok()),
            src_port: self.src_port.and_then(|v| v.as_u16()),
            dst_port: self.dst_port.and_then(|v| v.as_u16()),
            protocol_number: self.protocol.and_then(|v| v.as_u8()),
            protocol_type: self
                .protocol
                .and_then(|v| v.as_u8())
                .map(ProtocolTypes::from),
            first_seen: self.first_seen.and_then(|v| v.as_u64()),
            last_seen: self.last_seen.and_then(|v| v.as_u64()),
            src_mac: self.src_mac.and_then(|v| v.try_into().ok()),
            dst_mac: self.dst_mac.and_then(|v| v.try_into().ok()),
        }
    }

    fn from_v9_fields(fields: &'a [(V9Field, FieldValue)]) -> Self {
        let mut cache = Self::default();
        for (field_type, field_value) in fields {
            match field_type {
                V9Field::Ipv4SrcAddr => cache.src_addr = cache.src_addr.or(Some(field_value)),
                V9Field::Ipv6SrcAddr => cache.src_addr = cache.src_addr.or(Some(field_value)),
                V9Field::Ipv4DstAddr => cache.dst_addr = cache.dst_addr.or(Some(field_value)),
                V9Field::Ipv6DstAddr => cache.dst_addr = cache.dst_addr.or(Some(field_value)),
                V9Field::L4SrcPort => cache.src_port = Some(field_value),
                V9Field::L4DstPort => cache.dst_port = Some(field_value),
                V9Field::Protocol => cache.protocol = Some(field_value),
                V9Field::FirstSwitched => cache.first_seen = Some(field_value),
                V9Field::LastSwitched => cache.last_seen = Some(field_value),
                V9Field::InSrcMac => cache.src_mac = Some(field_value),
                V9Field::InDstMac => cache.dst_mac = Some(field_value),
                _ => {}
            }
        }
        cache
    }

    fn from_ipfix_fields(fields: &'a [(IPFixField, FieldValue)]) -> Self {
        let mut cache = Self::default();
        for (field_type, field_value) in fields {
            match field_type {
                IPFixField::IANA(IANAIPFixField::SourceIpv4address) => {
                    cache.src_addr = cache.src_addr.or(Some(field_value))
                }
                IPFixField::IANA(IANAIPFixField::SourceIpv6address) => {
                    cache.src_addr = cache.src_addr.or(Some(field_value))
                }
                IPFixField::IANA(IANAIPFixField::DestinationIpv4address) => {
                    cache.dst_addr = cache.dst_addr.or(Some(field_value))
                }
                IPFixField::IANA(IANAIPFixField::DestinationIpv6address) => {
                    cache.dst_addr = cache.dst_addr.or(Some(field_value))
                }
                IPFixField::IANA(IANAIPFixField::SourceTransportPort) => {
                    cache.src_port = Some(field_value)
                }
                IPFixField::IANA(IANAIPFixField::DestinationTransportPort) => {
                    cache.dst_port = Some(field_value)
                }
                IPFixField::IANA(IANAIPFixField::ProtocolIdentifier) => {
                    cache.protocol = Some(field_value)
                }
                IPFixField::IANA(IANAIPFixField::FlowStartSysUpTime) => {
                    cache.first_seen = Some(field_value)
                }
                IPFixField::IANA(IANAIPFixField::FlowEndSysUpTime) => {
                    cache.last_seen = Some(field_value)
                }
                IPFixField::IANA(IANAIPFixField::SourceMacaddress) => {
                    cache.src_mac = Some(field_value)
                }
                IPFixField::IANA(IANAIPFixField::DestinationMacaddress) => {
                    cache.dst_mac = Some(field_value)
                }
                _ => {}
            }
        }
        cache
    }
}

/// Macro to check if a field matches a config mapping (primary or fallback).
/// Works for both Copy types (V9Field) and reference types (IPFixField).
macro_rules! check_field_mapping {
    ($field_type:expr, $field_value:expr, $cache:expr, $config:expr, $field_name:ident) => {
        if *$field_type == $config.$field_name.primary {
            $cache.$field_name = Some($field_value);
        } else if $config.$field_name.fallback.as_ref() == Some($field_type)
            && $cache.$field_name.is_none()
        {
            $cache.$field_name = Some($field_value);
        }
    };
}

impl<'a> FieldCache<'a> {
    fn from_v9_fields_with_config(
        fields: &'a [(V9Field, FieldValue)],
        config: &V9FieldMappingConfig,
    ) -> Self {
        let mut cache = Self::default();
        for (field_type, field_value) in fields {
            check_field_mapping!(field_type, field_value, cache, config, src_addr);
            check_field_mapping!(field_type, field_value, cache, config, dst_addr);
            check_field_mapping!(field_type, field_value, cache, config, src_port);
            check_field_mapping!(field_type, field_value, cache, config, dst_port);
            check_field_mapping!(field_type, field_value, cache, config, protocol);
            check_field_mapping!(field_type, field_value, cache, config, first_seen);
            check_field_mapping!(field_type, field_value, cache, config, last_seen);
            check_field_mapping!(field_type, field_value, cache, config, src_mac);
            check_field_mapping!(field_type, field_value, cache, config, dst_mac);
        }
        cache
    }

    fn from_ipfix_fields_with_config(
        fields: &'a [(IPFixField, FieldValue)],
        config: &IPFixFieldMappingConfig,
    ) -> Self {
        let mut cache = Self::default();
        for (field_type, field_value) in fields {
            check_field_mapping!(field_type, field_value, cache, config, src_addr);
            check_field_mapping!(field_type, field_value, cache, config, dst_addr);
            check_field_mapping!(field_type, field_value, cache, config, src_port);
            check_field_mapping!(field_type, field_value, cache, config, dst_port);
            check_field_mapping!(field_type, field_value, cache, config, protocol);
            check_field_mapping!(field_type, field_value, cache, config, first_seen);
            check_field_mapping!(field_type, field_value, cache, config, last_seen);
            check_field_mapping!(field_type, field_value, cache, config, src_mac);
            check_field_mapping!(field_type, field_value, cache, config, dst_mac);
        }
        cache
    }
}

/// Collect common flowsets from V9 flowset bodies.
fn collect_v9_flowsets(value: &V9) -> Vec<NetflowCommonFlowSet> {
    let mut flowsets = vec![];
    for flowset in &value.flowsets {
        match &flowset.body {
            V9FlowSetBody::Data(data) => {
                for record in &data.fields {
                    flowsets.push(FieldCache::from_v9_fields(record).to_common_flowset());
                }
            }
            V9FlowSetBody::OptionsData(opts_data) => {
                for record in &opts_data.fields {
                    flowsets.push(
                        FieldCache::from_v9_fields(&record.options_fields).to_common_flowset(),
                    );
                }
            }
            V9FlowSetBody::Template(_)
            | V9FlowSetBody::OptionsTemplate(_)
            | V9FlowSetBody::NoTemplate(_)
            | V9FlowSetBody::Empty => {}
        }
    }
    flowsets
}

/// Collect common flowsets from V9 flowset bodies using a custom config.
fn collect_v9_flowsets_with_config(
    value: &V9,
    config: &V9FieldMappingConfig,
) -> Vec<NetflowCommonFlowSet> {
    let mut flowsets = vec![];
    for flowset in &value.flowsets {
        match &flowset.body {
            V9FlowSetBody::Data(data) => {
                for record in &data.fields {
                    flowsets.push(
                        FieldCache::from_v9_fields_with_config(record, config)
                            .to_common_flowset(),
                    );
                }
            }
            V9FlowSetBody::OptionsData(opts_data) => {
                for record in &opts_data.fields {
                    flowsets.push(
                        FieldCache::from_v9_fields_with_config(&record.options_fields, config)
                            .to_common_flowset(),
                    );
                }
            }
            V9FlowSetBody::Template(_)
            | V9FlowSetBody::OptionsTemplate(_)
            | V9FlowSetBody::NoTemplate(_)
            | V9FlowSetBody::Empty => {}
        }
    }
    flowsets
}

/// Collect common flowsets from IPFIX flowset bodies.
/// Embedded V9-style flowsets use V9 field mapping.
fn collect_ipfix_flowsets(value: &IPFix) -> Vec<NetflowCommonFlowSet> {
    let mut flowsets = vec![];
    for flowset in &value.flowsets {
        match &flowset.body {
            IPFixFlowSetBody::Data(data) => {
                for record in &data.fields {
                    flowsets.push(FieldCache::from_ipfix_fields(record).to_common_flowset());
                }
            }
            IPFixFlowSetBody::OptionsData(opts_data) => {
                for record in &opts_data.fields {
                    flowsets.push(FieldCache::from_ipfix_fields(record).to_common_flowset());
                }
            }
            IPFixFlowSetBody::V9Data(v9_data) => {
                for record in &v9_data.fields {
                    flowsets.push(FieldCache::from_v9_fields(record).to_common_flowset());
                }
            }
            IPFixFlowSetBody::V9OptionsData(v9_opts_data) => {
                for record in &v9_opts_data.fields {
                    flowsets.push(
                        FieldCache::from_v9_fields(&record.options_fields).to_common_flowset(),
                    );
                }
            }
            IPFixFlowSetBody::Template(_)
            | IPFixFlowSetBody::Templates(_)
            | IPFixFlowSetBody::V9Template(_)
            | IPFixFlowSetBody::V9Templates(_)
            | IPFixFlowSetBody::OptionsTemplate(_)
            | IPFixFlowSetBody::OptionsTemplates(_)
            | IPFixFlowSetBody::V9OptionsTemplate(_)
            | IPFixFlowSetBody::V9OptionsTemplates(_)
            | IPFixFlowSetBody::NoTemplate(_)
            | IPFixFlowSetBody::Empty => {}
        }
    }
    flowsets
}

/// Collect common flowsets from IPFIX flowset bodies using a custom config.
/// Embedded V9-style flowsets use default V9 field mapping (config is IPFIX-only).
fn collect_ipfix_flowsets_with_config(
    value: &IPFix,
    config: &IPFixFieldMappingConfig,
) -> Vec<NetflowCommonFlowSet> {
    let mut flowsets = vec![];
    for flowset in &value.flowsets {
        match &flowset.body {
            IPFixFlowSetBody::Data(data) => {
                for record in &data.fields {
                    flowsets.push(
                        FieldCache::from_ipfix_fields_with_config(record, config)
                            .to_common_flowset(),
                    );
                }
            }
            IPFixFlowSetBody::OptionsData(opts_data) => {
                for record in &opts_data.fields {
                    flowsets.push(
                        FieldCache::from_ipfix_fields_with_config(record, config)
                            .to_common_flowset(),
                    );
                }
            }
            // V9-style flowsets embedded in IPFIX use V9 field types
            IPFixFlowSetBody::V9Data(v9_data) => {
                for record in &v9_data.fields {
                    flowsets.push(FieldCache::from_v9_fields(record).to_common_flowset());
                }
            }
            IPFixFlowSetBody::V9OptionsData(v9_opts_data) => {
                for record in &v9_opts_data.fields {
                    flowsets.push(
                        FieldCache::from_v9_fields(&record.options_fields).to_common_flowset(),
                    );
                }
            }
            IPFixFlowSetBody::Template(_)
            | IPFixFlowSetBody::Templates(_)
            | IPFixFlowSetBody::V9Template(_)
            | IPFixFlowSetBody::V9Templates(_)
            | IPFixFlowSetBody::OptionsTemplate(_)
            | IPFixFlowSetBody::OptionsTemplates(_)
            | IPFixFlowSetBody::V9OptionsTemplate(_)
            | IPFixFlowSetBody::V9OptionsTemplates(_)
            | IPFixFlowSetBody::NoTemplate(_)
            | IPFixFlowSetBody::Empty => {}
        }
    }
    flowsets
}

impl NetflowCommon {
    /// Convert a V9 packet to NetflowCommon using a custom field mapping configuration.
    ///
    /// This allows you to specify which V9 fields should be used for each
    /// NetflowCommonFlowSet field, including fallback fields.
    ///
    /// # Example
    ///
    /// ```rust
    /// use netflow_parser::netflow_common::V9FieldMappingConfig;
    /// use netflow_parser::variable_versions::v9::lookup::V9Field;
    ///
    /// // Use custom configuration that prefers IPv6
    /// let mut config = V9FieldMappingConfig::default();
    /// config.src_addr.primary = V9Field::Ipv6SrcAddr;
    /// config.src_addr.fallback = Some(V9Field::Ipv4SrcAddr);
    ///
    /// // Then use: NetflowCommon::from_v9_with_config(&v9, &config);
    /// ```
    pub fn from_v9_with_config(value: &V9, config: &V9FieldMappingConfig) -> Self {
        NetflowCommon {
            version: value.header.version,
            timestamp: value.header.sys_up_time,
            flowsets: collect_v9_flowsets_with_config(value, config),
        }
    }
}

impl From<&V9> for NetflowCommon {
    fn from(value: &V9) -> Self {
        NetflowCommon {
            version: value.header.version,
            timestamp: value.header.sys_up_time,
            flowsets: collect_v9_flowsets(value),
        }
    }
}

impl NetflowCommon {
    /// Convert an IPFIX packet to NetflowCommon using a custom field mapping configuration.
    ///
    /// This allows you to specify which IPFIX fields should be used for each
    /// NetflowCommonFlowSet field, including fallback fields.
    ///
    /// **Note:** Embedded V9-style data flowsets (`V9Data`, `V9OptionsData`) use V9 field
    /// types rather than IPFIX field types, so the custom `config` is not applied to them.
    /// Those flowsets are converted using the default V9 field mapping instead.
    ///
    /// # Example
    ///
    /// ```rust
    /// use netflow_parser::netflow_common::IPFixFieldMappingConfig;
    /// use netflow_parser::variable_versions::ipfix::lookup::{IPFixField, IANAIPFixField};
    ///
    /// // Use custom configuration that prefers IPv6
    /// let mut config = IPFixFieldMappingConfig::default();
    /// config.src_addr.primary = IPFixField::IANA(IANAIPFixField::SourceIpv6address);
    /// config.src_addr.fallback = Some(IPFixField::IANA(IANAIPFixField::SourceIpv4address));
    ///
    /// // Then use: NetflowCommon::from_ipfix_with_config(&ipfix, &config);
    /// ```
    pub fn from_ipfix_with_config(value: &IPFix, config: &IPFixFieldMappingConfig) -> Self {
        NetflowCommon {
            version: value.header.version,
            timestamp: value.header.export_time,
            flowsets: collect_ipfix_flowsets_with_config(value, config),
        }
    }
}

impl From<&IPFix> for NetflowCommon {
    fn from(value: &IPFix) -> Self {
        NetflowCommon {
            version: value.header.version,
            timestamp: value.header.export_time,
            flowsets: collect_ipfix_flowsets(value),
        }
    }
}

#[cfg(test)]
mod common_tests {
    use std::net::{IpAddr, Ipv4Addr};

    use crate::netflow_common::NetflowCommon;
    use crate::static_versions::v5::{FlowSet as V5FlowSet, Header as V5Header, V5};
    use crate::static_versions::v7::{FlowSet as V7FlowSet, Header as V7Header, V7};
    use crate::variable_versions::field_value::{DataNumber, FieldValue};
    use crate::variable_versions::ipfix::lookup::{IANAIPFixField, IPFixField};
    use crate::variable_versions::ipfix::{
        Data as IPFixData, FlowSet as IPFixFlowSet, FlowSetBody as IPFixFlowSetBody,
        FlowSetHeader as IPFixFlowSetHeader, Header as IPFixHeader, IPFix,
        OptionsData as IPFixOptionsData,
    };
    use crate::variable_versions::v9::lookup::V9Field;
    use crate::variable_versions::v9::{
        Data as V9Data, FlowSet as V9FlowSet, FlowSetBody as V9FlowSetBody,
        FlowSetHeader as V9FlowSetHeader, Header as V9Header, OptionsData as V9OptionsData,
        OptionsDataFields as V9OptionsDataFields, ScopeDataField, V9,
    };

    #[test]
    fn it_converts_v5_to_common() {
        let v5 = V5 {
            header: V5Header {
                version: 5,
                count: 1,
                sys_up_time: 100,
                unix_secs: 1609459200,
                unix_nsecs: 0,
                flow_sequence: 1,
                engine_type: 0,
                engine_id: 0,
                sampling_interval: 0,
            },
            flowsets: vec![V5FlowSet {
                src_addr: Ipv4Addr::new(192, 168, 1, 1),
                dst_addr: Ipv4Addr::new(192, 168, 1, 2),
                src_port: 1234,
                dst_port: 80,
                protocol_number: 6,
                protocol_type: crate::protocol::ProtocolTypes::Tcp,
                next_hop: Ipv4Addr::new(192, 168, 1, 254),
                input: 0,
                output: 0,
                d_pkts: 10,
                d_octets: 1000,
                first: 100,
                last: 200,
                pad1: 0,
                tcp_flags: 0,
                tos: 0,
                src_as: 0,
                dst_as: 0,
                src_mask: 0,
                dst_mask: 0,
                pad2: 0,
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&v5);

        assert_eq!(common.version, 5);
        assert_eq!(common.timestamp, 100);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );
        assert_eq!(
            flowset.dst_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 2))
        );
        assert_eq!(flowset.src_port.unwrap(), 1234);
        assert_eq!(flowset.dst_port.unwrap(), 80);
        assert_eq!(flowset.protocol_number.unwrap(), 6);
        assert_eq!(
            flowset.protocol_type.unwrap(),
            crate::protocol::ProtocolTypes::Tcp
        );
        assert_eq!(flowset.first_seen.unwrap(), 100);
        assert_eq!(flowset.last_seen.unwrap(), 200);
    }

    #[test]
    fn it_converts_v7_to_common() {
        let v7 = V7 {
            header: V7Header {
                version: 7,
                count: 1,
                sys_up_time: 100,
                unix_secs: 1609459200,
                unix_nsecs: 0,
                flow_sequence: 1,
                reserved: 0,
            },
            flowsets: vec![V7FlowSet {
                src_addr: Ipv4Addr::new(192, 168, 1, 1),
                dst_addr: Ipv4Addr::new(192, 168, 1, 2),
                src_port: 1234,
                dst_port: 80,
                protocol_number: 6,
                protocol_type: crate::protocol::ProtocolTypes::Tcp,
                next_hop: Ipv4Addr::new(192, 168, 1, 254),
                input: 0,
                output: 0,
                d_pkts: 10,
                d_octets: 1000,
                first: 100,
                last: 200,
                tcp_flags: 0,
                tos: 0,
                src_as: 0,
                dst_as: 0,
                src_mask: 0,
                dst_mask: 0,
                flags_fields_invalid: 0,
                flags_fields_valid: 0,
                router_src: Ipv4Addr::new(192, 168, 1, 254),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&v7);

        assert_eq!(common.version, 7);
        assert_eq!(common.timestamp, 100);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );
        assert_eq!(
            flowset.dst_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 2))
        );
        assert_eq!(flowset.src_port.unwrap(), 1234);
        assert_eq!(flowset.dst_port.unwrap(), 80);
        assert_eq!(flowset.protocol_number.unwrap(), 6);
        assert_eq!(
            flowset.protocol_type.unwrap(),
            crate::protocol::ProtocolTypes::Tcp
        );
        assert_eq!(flowset.first_seen.unwrap(), 100);
        assert_eq!(flowset.last_seen.unwrap(), 200);
    }

    #[test]
    fn it_converts_v9_to_common() {
        // Test for V9 conversion
        let v9 = V9 {
            header: V9Header {
                version: 9,
                count: 1,
                sys_up_time: 100,
                unix_secs: 1609459200,
                sequence_number: 1,
                source_id: 0,
            },
            flowsets: vec![V9FlowSet {
                header: V9FlowSetHeader {
                    flowset_id: 0,
                    length: 0,
                },
                body: V9FlowSetBody::Data(V9Data {
                    padding: vec![],
                    fields: vec![Vec::from([
                        (
                            V9Field::Ipv4SrcAddr,
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 1, 1)),
                        ),
                        (
                            V9Field::Ipv4DstAddr,
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 1, 2)),
                        ),
                        (
                            V9Field::L4SrcPort,
                            FieldValue::DataNumber(DataNumber::U16(1234)),
                        ),
                        (
                            V9Field::L4DstPort,
                            FieldValue::DataNumber(DataNumber::U16(80)),
                        ),
                        (V9Field::Protocol, FieldValue::DataNumber(DataNumber::U8(6))),
                        (
                            V9Field::FirstSwitched,
                            FieldValue::DataNumber(DataNumber::U32(100)),
                        ),
                        (
                            V9Field::LastSwitched,
                            FieldValue::DataNumber(DataNumber::U32(200)),
                        ),
                        (
                            V9Field::InSrcMac,
                            FieldValue::MacAddr([0x00, 0x00, 0x00, 0x00, 0x00, 0x01]),
                        ),
                        (
                            V9Field::InDstMac,
                            FieldValue::MacAddr([0x00, 0x00, 0x00, 0x00, 0x00, 0x02]),
                        ),
                    ])],
                }),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&v9);
        assert_eq!(common.version, 9);
        assert_eq!(common.timestamp, 100);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );
        assert_eq!(
            flowset.dst_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 2))
        );
        assert_eq!(flowset.src_port.unwrap(), 1234);
        assert_eq!(flowset.dst_port.unwrap(), 80);
        assert_eq!(flowset.protocol_number.unwrap(), 6);
        assert_eq!(
            flowset.protocol_type.unwrap(),
            crate::protocol::ProtocolTypes::Tcp
        );
        assert_eq!(flowset.first_seen.unwrap(), 100);
        assert_eq!(flowset.last_seen.unwrap(), 200);
        assert_eq!(flowset.src_mac.as_ref().unwrap(), "00:00:00:00:00:01");
        assert_eq!(flowset.dst_mac.as_ref().unwrap(), "00:00:00:00:00:02");
    }

    #[test]
    fn it_converts_ipfix_to_common() {
        // Test for IPFix conversion
        let ipfix = IPFix {
            header: IPFixHeader {
                version: 10,
                length: 0,
                export_time: 100,
                sequence_number: 1,
                observation_domain_id: 0,
            },
            flowsets: vec![IPFixFlowSet {
                header: IPFixFlowSetHeader {
                    header_id: 0,
                    length: 0,
                },
                body: IPFixFlowSetBody::Data(IPFixData {
                    fields: vec![Vec::from([
                        (
                            IPFixField::IANA(IANAIPFixField::SourceIpv4address),
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 1, 1)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::DestinationIpv4address),
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 1, 2)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::SourceTransportPort),
                            FieldValue::DataNumber(DataNumber::U16(1234)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::DestinationTransportPort),
                            FieldValue::DataNumber(DataNumber::U16(80)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::ProtocolIdentifier),
                            FieldValue::DataNumber(DataNumber::U8(6)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::FlowStartSysUpTime),
                            FieldValue::DataNumber(DataNumber::U32(100)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::FlowEndSysUpTime),
                            FieldValue::DataNumber(DataNumber::U32(200)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::SourceMacaddress),
                            FieldValue::MacAddr([0x00, 0x00, 0x00, 0x00, 0x00, 0x01]),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::DestinationMacaddress),
                            FieldValue::MacAddr([0x00, 0x00, 0x00, 0x00, 0x00, 0x02]),
                        ),
                    ])],
                    padding: vec![],
                    template_field_lengths: vec![],
                }),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&ipfix);
        assert_eq!(common.version, 10);
        assert_eq!(common.timestamp, 100);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );
        assert_eq!(
            flowset.dst_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 2))
        );
        assert_eq!(flowset.src_port.unwrap(), 1234);
        assert_eq!(flowset.dst_port.unwrap(), 80);
        assert_eq!(flowset.protocol_number.unwrap(), 6);
        assert_eq!(
            flowset.protocol_type.unwrap(),
            crate::protocol::ProtocolTypes::Tcp
        );
        assert_eq!(flowset.first_seen.unwrap(), 100);
        assert_eq!(flowset.last_seen.unwrap(), 200);
        assert_eq!(flowset.src_mac.as_ref().unwrap(), "00:00:00:00:00:01");
        assert_eq!(flowset.dst_mac.as_ref().unwrap(), "00:00:00:00:00:02");
    }

    #[test]
    fn it_converts_v9_duration_timestamps_to_common() {
        // Verify that Duration-typed timestamp fields (DurationMillis) are
        // correctly extracted. This is the real wire format — FirstSwitched
        // and LastSwitched are typed as DurationMillis in v9_lookup.rs.
        use crate::variable_versions::field_value::DurationValue;

        let v9 = V9 {
            header: V9Header {
                version: 9,
                count: 1,
                sys_up_time: 100,
                unix_secs: 1609459200,
                sequence_number: 1,
                source_id: 0,
            },
            flowsets: vec![V9FlowSet {
                header: V9FlowSetHeader {
                    flowset_id: 0,
                    length: 0,
                },
                body: V9FlowSetBody::Data(V9Data {
                    padding: vec![],
                    fields: vec![Vec::from([
                        (
                            V9Field::Ipv4SrcAddr,
                            FieldValue::Ip4Addr(Ipv4Addr::new(10, 0, 0, 1)),
                        ),
                        (
                            V9Field::Ipv4DstAddr,
                            FieldValue::Ip4Addr(Ipv4Addr::new(10, 0, 0, 2)),
                        ),
                        (
                            V9Field::FirstSwitched,
                            FieldValue::Duration(DurationValue::Millis {
                                value: 50000,
                                width: 4,
                            }),
                        ),
                        (
                            V9Field::LastSwitched,
                            FieldValue::Duration(DurationValue::Millis {
                                value: 60000,
                                width: 4,
                            }),
                        ),
                    ])],
                }),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&v9);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(flowset.first_seen.unwrap(), 50000);
        assert_eq!(flowset.last_seen.unwrap(), 60000);
    }

    #[test]
    fn it_converts_v9_to_common_with_custom_config() {
        use crate::netflow_common::V9FieldMappingConfig;
        use std::net::Ipv6Addr;

        // Create a V9 packet with both IPv4 and IPv6 addresses
        let v9 = V9 {
            header: V9Header {
                version: 9,
                count: 1,
                sys_up_time: 100,
                unix_secs: 1609459200,
                sequence_number: 1,
                source_id: 0,
            },
            flowsets: vec![V9FlowSet {
                header: V9FlowSetHeader {
                    flowset_id: 0,
                    length: 0,
                },
                body: V9FlowSetBody::Data(V9Data {
                    padding: vec![],
                    fields: vec![Vec::from([
                        (
                            V9Field::Ipv4SrcAddr,
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 1, 1)),
                        ),
                        (
                            V9Field::Ipv6SrcAddr,
                            FieldValue::Ip6Addr(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)),
                        ),
                        (
                            V9Field::L4SrcPort,
                            FieldValue::DataNumber(DataNumber::U16(1234)),
                        ),
                    ])],
                }),
            }],
        };

        // Default config prefers IPv4
        let default_config = V9FieldMappingConfig::default();
        let common = NetflowCommon::from_v9_with_config(&v9, &default_config);
        assert_eq!(
            common.flowsets[0].src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );

        // Custom config that prefers IPv6
        let mut ipv6_config = V9FieldMappingConfig::default();
        ipv6_config.src_addr.primary = V9Field::Ipv6SrcAddr;
        ipv6_config.src_addr.fallback = Some(V9Field::Ipv4SrcAddr);

        let common_ipv6 = NetflowCommon::from_v9_with_config(&v9, &ipv6_config);
        assert_eq!(
            common_ipv6.flowsets[0].src_addr.unwrap(),
            IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1))
        );
    }

    #[test]
    fn it_converts_ipfix_to_common_with_custom_config() {
        use crate::netflow_common::IPFixFieldMappingConfig;
        use std::net::Ipv6Addr;

        // Create an IPFIX packet with both IPv4 and IPv6 addresses
        let ipfix = IPFix {
            header: IPFixHeader {
                version: 10,
                length: 0,
                export_time: 100,
                sequence_number: 1,
                observation_domain_id: 0,
            },
            flowsets: vec![IPFixFlowSet {
                header: IPFixFlowSetHeader {
                    header_id: 0,
                    length: 0,
                },
                body: IPFixFlowSetBody::Data(IPFixData {
                    fields: vec![Vec::from([
                        (
                            IPFixField::IANA(IANAIPFixField::SourceIpv4address),
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 1, 1)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::SourceIpv6address),
                            FieldValue::Ip6Addr(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)),
                        ),
                        (
                            IPFixField::IANA(IANAIPFixField::SourceTransportPort),
                            FieldValue::DataNumber(DataNumber::U16(1234)),
                        ),
                    ])],
                    padding: vec![],
                    template_field_lengths: vec![],
                }),
            }],
        };

        // Default config prefers IPv4
        let default_config = IPFixFieldMappingConfig::default();
        let common = NetflowCommon::from_ipfix_with_config(&ipfix, &default_config);
        assert_eq!(
            common.flowsets[0].src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );

        // Custom config that prefers IPv6
        let mut ipv6_config = IPFixFieldMappingConfig::default();
        ipv6_config.src_addr.primary = IPFixField::IANA(IANAIPFixField::SourceIpv6address);
        ipv6_config.src_addr.fallback =
            Some(IPFixField::IANA(IANAIPFixField::SourceIpv4address));

        let common_ipv6 = NetflowCommon::from_ipfix_with_config(&ipfix, &ipv6_config);
        assert_eq!(
            common_ipv6.flowsets[0].src_addr.unwrap(),
            IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1))
        );
    }

    #[test]
    fn it_uses_fallback_when_primary_not_found() {
        use crate::netflow_common::V9FieldMappingConfig;

        // Create a V9 packet with only IPv6 address (no IPv4)
        let v9 = V9 {
            header: V9Header {
                version: 9,
                count: 1,
                sys_up_time: 100,
                unix_secs: 1609459200,
                sequence_number: 1,
                source_id: 0,
            },
            flowsets: vec![V9FlowSet {
                header: V9FlowSetHeader {
                    flowset_id: 0,
                    length: 0,
                },
                body: V9FlowSetBody::Data(V9Data {
                    padding: vec![],
                    fields: vec![Vec::from([(
                        V9Field::Ipv4SrcAddr,
                        FieldValue::Ip4Addr(Ipv4Addr::new(10, 0, 0, 1)),
                    )])],
                }),
            }],
        };

        // Config that prefers IPv6 but falls back to IPv4
        let mut config = V9FieldMappingConfig::default();
        config.src_addr.primary = V9Field::Ipv6SrcAddr;
        config.src_addr.fallback = Some(V9Field::Ipv4SrcAddr);

        let common = NetflowCommon::from_v9_with_config(&v9, &config);
        // Should fall back to IPv4 since IPv6 is not present
        assert_eq!(
            common.flowsets[0].src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))
        );
    }

    #[test]
    fn it_converts_v9_options_data_to_common() {
        let v9 = V9 {
            header: V9Header {
                version: 9,
                count: 1,
                sys_up_time: 100,
                unix_secs: 1609459200,
                sequence_number: 1,
                source_id: 0,
            },
            flowsets: vec![V9FlowSet {
                header: V9FlowSetHeader {
                    flowset_id: 0,
                    length: 0,
                },
                body: V9FlowSetBody::OptionsData(V9OptionsData {
                    fields: vec![V9OptionsDataFields {
                        scope_fields: vec![ScopeDataField::System(vec![0, 0, 0, 1])],
                        options_fields: vec![
                            (
                                V9Field::Ipv4SrcAddr,
                                FieldValue::Ip4Addr(Ipv4Addr::new(10, 1, 2, 3)),
                            ),
                            (
                                V9Field::L4SrcPort,
                                FieldValue::DataNumber(DataNumber::U16(443)),
                            ),
                        ],
                    }],
                }),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&v9);
        assert_eq!(common.version, 9);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(10, 1, 2, 3))
        );
        assert_eq!(flowset.src_port.unwrap(), 443);
    }

    #[test]
    fn it_converts_ipfix_options_data_to_common() {
        let ipfix = IPFix {
            header: IPFixHeader {
                version: 10,
                length: 0,
                export_time: 200,
                sequence_number: 1,
                observation_domain_id: 0,
            },
            flowsets: vec![IPFixFlowSet {
                header: IPFixFlowSetHeader {
                    header_id: 0,
                    length: 0,
                },
                body: IPFixFlowSetBody::OptionsData(IPFixOptionsData::new(vec![vec![
                    (
                        IPFixField::IANA(IANAIPFixField::SourceIpv4address),
                        FieldValue::Ip4Addr(Ipv4Addr::new(172, 16, 0, 1)),
                    ),
                    (
                        IPFixField::IANA(IANAIPFixField::DestinationTransportPort),
                        FieldValue::DataNumber(DataNumber::U16(8080)),
                    ),
                ]])),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&ipfix);
        assert_eq!(common.version, 10);
        assert_eq!(common.timestamp, 200);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(172, 16, 0, 1))
        );
        assert_eq!(flowset.dst_port.unwrap(), 8080);
    }

    #[test]
    fn it_converts_ipfix_v9data_to_common() {
        // V9Data embedded inside an IPFIX message
        let ipfix = IPFix {
            header: IPFixHeader {
                version: 10,
                length: 0,
                export_time: 300,
                sequence_number: 1,
                observation_domain_id: 0,
            },
            flowsets: vec![IPFixFlowSet {
                header: IPFixFlowSetHeader {
                    header_id: 0,
                    length: 0,
                },
                body: IPFixFlowSetBody::V9Data(V9Data {
                    padding: vec![],
                    fields: vec![Vec::from([
                        (
                            V9Field::Ipv4SrcAddr,
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 10, 1)),
                        ),
                        (
                            V9Field::Ipv4DstAddr,
                            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 10, 2)),
                        ),
                        (
                            V9Field::Protocol,
                            FieldValue::DataNumber(DataNumber::U8(17)),
                        ),
                    ])],
                }),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&ipfix);
        assert_eq!(common.version, 10);
        assert_eq!(common.timestamp, 300);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.src_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 10, 1))
        );
        assert_eq!(
            flowset.dst_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 10, 2))
        );
        assert_eq!(flowset.protocol_number.unwrap(), 17);
    }

    #[test]
    fn it_converts_ipfix_v9_options_data_to_common() {
        // V9OptionsData embedded inside an IPFIX message
        let ipfix = IPFix {
            header: IPFixHeader {
                version: 10,
                length: 0,
                export_time: 400,
                sequence_number: 1,
                observation_domain_id: 0,
            },
            flowsets: vec![IPFixFlowSet {
                header: IPFixFlowSetHeader {
                    header_id: 0,
                    length: 0,
                },
                body: IPFixFlowSetBody::V9OptionsData(V9OptionsData {
                    fields: vec![V9OptionsDataFields {
                        scope_fields: vec![ScopeDataField::Interface(vec![0, 0, 0, 2])],
                        options_fields: vec![
                            (
                                V9Field::Ipv4DstAddr,
                                FieldValue::Ip4Addr(Ipv4Addr::new(10, 10, 10, 1)),
                            ),
                            (
                                V9Field::L4DstPort,
                                FieldValue::DataNumber(DataNumber::U16(53)),
                            ),
                        ],
                    }],
                }),
            }],
        };

        let common: NetflowCommon = NetflowCommon::from(&ipfix);
        assert_eq!(common.version, 10);
        assert_eq!(common.timestamp, 400);
        assert_eq!(common.flowsets.len(), 1);
        let flowset = &common.flowsets[0];
        assert_eq!(
            flowset.dst_addr.unwrap(),
            IpAddr::V4(Ipv4Addr::new(10, 10, 10, 1))
        );
        assert_eq!(flowset.dst_port.unwrap(), 53);
        // Scope fields should be ignored (they're metadata, not flow data)
        assert!(flowset.src_addr.is_none());
    }
}
