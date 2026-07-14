//! IPFIX type definitions — structs, enums, traits, and nom-derived parsing.
//!
//! This module contains all public data types for the IPFIX protocol. Declarative
//! parsing is embedded via `#[derive(Nom)]` attributes. The stateful parser
//! (`IPFixParser`) and manual parse impl blocks live in `parser.rs`.

use super::lookup::IPFixField;
use crate::template_store::TemplateStore;
use crate::variable_versions::PendingFlowCache;
use crate::variable_versions::enterprise_registry::EnterpriseFieldRegistry;
use crate::variable_versions::field_value::FieldValue;
use crate::variable_versions::metrics::CacheMetricsInner;
use crate::variable_versions::template_events::TemplateProtocol;
use crate::variable_versions::ttl::{TemplateWithTtl, TtlConfig};

use nom::bytes::complete::take;
use nom::combinator::{complete, map_res};
use nom::multi::{count, many0};
use nom_derive::{Nom, Parse};
use serde::Serialize;

use crate::variable_versions::v9::{
    Data as V9Data, OptionsData as V9OptionsData, OptionsTemplate as V9OptionsTemplate,
    Template as V9Template,
};

use lru::LruCache;
use std::sync::Arc;

use crate::variable_versions::TemplateId;

pub(crate) const DATA_TEMPLATE_IPFIX_ID: u16 = 2;
pub(crate) const OPTIONS_TEMPLATE_IPFIX_ID: u16 = 3;
pub type IPFixFieldPair = (IPFixField, FieldValue);
pub type IPFixFlowRecord = Vec<IPFixFieldPair>;
/// Stateful IPFIX parser with LRU template caches and optional pending flow support.
/// Supports both native IPFIX templates and V9-style templates embedded in IPFIX messages.
#[derive(Debug)]
pub struct IPFixParser {
    pub(crate) templates: LruCache<TemplateId, TemplateWithTtl<Arc<Template>>>,
    pub(crate) v9_templates: LruCache<TemplateId, TemplateWithTtl<Arc<V9Template>>>,
    pub(crate) ipfix_options_templates:
        LruCache<TemplateId, TemplateWithTtl<Arc<OptionsTemplate>>>,
    pub(crate) v9_options_templates:
        LruCache<TemplateId, TemplateWithTtl<Arc<V9OptionsTemplate>>>,
    pub(crate) ttl_config: Option<TtlConfig>,
    pub(crate) max_template_cache_size: usize,
    pub(crate) max_field_count: usize,
    pub(crate) max_template_total_size: usize,
    pub(crate) max_error_sample_size: usize,
    pub(crate) max_records_per_flowset: usize,
    pub(crate) enterprise_registry: Arc<EnterpriseFieldRegistry>,
    pub(crate) metrics: CacheMetricsInner,
    pub(crate) pending_flows: Option<PendingFlowCache>,
    /// Optional secondary-tier template store. See [`crate::template_store`].
    pub(crate) template_store: Option<Arc<dyn TemplateStore>>,
    /// Scope written into every store key. Empty for single-source parsers;
    /// `AutoScopedParser` overrides this per source. Held as `Arc<str>` so
    /// per-key clones are cheap refcount bumps.
    pub(crate) template_store_scope: Arc<str>,
    /// Templates restored via the secondary store during the in-flight
    /// parse. Drained after each `parse` call to fire `TemplateEvent::Restored`
    /// hooks and to drive pending-flow replay.
    pub(crate) restored_templates: Vec<(TemplateProtocol, u16)>,
}

/// A parsed IPFIX message containing a header and a list of flowsets.
#[derive(Nom, Debug, PartialEq, Clone, Serialize)]
#[nom(ExtraArgs(parser: &mut IPFixParser))]
pub struct IPFix {
    /// IPFix Header
    pub header: Header,
    /// Sets
    #[nom(
        PreExec = "let length = header.length.checked_sub(16).ok_or(nom::Err::Error(nom::error::Error::new(i, nom::error::ErrorKind::Verify)))?;",
        Parse = "map_res(take(length), |i| {
            many0(complete(|i| FlowSet::parse(i, parser)
                .map(|(i, flow_set)| (i, flow_set))
            ))(i)
            .map(|(_, flow_sets)| flow_sets) // Extract the Vec<FlowSet>
        })"
    )]
    pub flowsets: Vec<FlowSet>,
}

pub use crate::variable_versions::NoTemplateInfo;

/// The payload of an IPFIX flowset: template definitions, data records, options,
/// V9-style templates/data, or a placeholder when the required template is missing.
#[derive(Debug, PartialEq, Clone, Serialize)]
pub enum FlowSetBody {
    Template(Template),
    Templates(Vec<Template>),
    V9Template(V9Template),
    V9Templates(Vec<V9Template>),
    OptionsTemplate(OptionsTemplate),
    OptionsTemplates(Vec<OptionsTemplate>),
    V9OptionsTemplate(V9OptionsTemplate),
    V9OptionsTemplates(Vec<V9OptionsTemplate>),
    Data(Data),
    OptionsData(OptionsData),
    V9Data(V9Data),
    V9OptionsData(V9OptionsData),
    NoTemplate(NoTemplateInfo),
    Empty,
}

/// IPFIX message header (RFC 7011 Section 3.1).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize, Nom)]
pub struct Header {
    /// Version of Flow Record format that is exported in this message. The value of this
    /// field is 0x000a for the current version, incrementing by one the version that is
    /// used in the NetFlow services export version 9
    #[nom(Value = "10")]
    pub version: u16,
    /// Total length of the IPFIX Message, which is measured in octets, including Message
    /// Header and Sets.
    pub length: u16,
    /// Time, in seconds, since 0000 Coordinated Universal Time Jan 1, 1970, at which the
    /// IPFIX Message Header leaves the Exporter.
    pub export_time: u32,
    /// Incremental sequence counter-modulo 2^32 of all IPFIX Data Records sent on this PR-SCTP
    /// stream from the current Observation Domain by the Exporting Process.
    pub sequence_number: u32,
    /// A 32-bit identifier of the Observation Domain that is locally unique to the Exporting Process.
    pub observation_domain_id: u32,
}

/// A single set within an IPFIX message, containing a header and a body.
#[derive(Debug, PartialEq, Clone, Serialize, Nom)]
#[nom(ExtraArgs(parser: &mut IPFixParser))]
pub struct FlowSet {
    pub header: FlowSetHeader,
    #[nom(
        PreExec = "let length = header.length.checked_sub(4).ok_or(nom::Err::Error(nom::error::Error::new(i, nom::error::ErrorKind::Verify)))?;",
        Parse = "map_res(take(length),
                  |i| FlowSetBody::parse(i, parser, header.header_id)
                      .map(|(_, flow_set)| flow_set))"
    )]
    pub body: FlowSetBody,
}

/// Header of an IPFIX set, identifying its type (template, options, or data) and length.
#[derive(Debug, PartialEq, Clone, Serialize, Nom)]
pub struct FlowSetHeader {
    /// Set ID value identifies the Set.
    pub header_id: u16,
    /// Total length of the Set, in octets, including the Set Header, all records, and the
    /// optional padding.
    pub length: u16,
}

/// Parsed IPFIX data records decoded using an IPFIX template.
#[derive(Debug, Clone, Serialize, Nom)]
#[nom(ExtraArgs(template: &Template))]
pub struct Data {
    #[nom(
        ErrorIf = "template.get_fields().is_empty() ",
        Parse = "{ |i| FieldParser::parse::<Template>(i, template, crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET) }"
    )]
    pub fields: Vec<IPFixFlowRecord>,
    #[serde(skip_serializing)]
    pub padding: Vec<u8>,
    /// Original template field lengths, used to emit RFC 7011 variable-length
    /// prefixes during serialization.  Not included in equality comparisons.
    /// Only populated when the template contains variable-length fields
    /// (field_length == 65535) to avoid unnecessary allocations.
    #[serde(skip_serializing)]
    #[nom(Value({
        let fields = template.get_fields();
        if fields.iter().any(|f| f.field_length == 65535) {
            fields.iter().map(|f| f.field_length).collect::<Vec<u16>>()
        } else {
            Vec::new()
        }
    }))]
    pub(crate) template_field_lengths: Vec<u16>,
}

impl PartialEq for Data {
    fn eq(&self, other: &Self) -> bool {
        self.fields == other.fields && self.padding == other.padding
    }
}

impl Data {
    /// Creates a new Data instance with the given fields.
    ///
    /// The resulting `Data` has no template field length metadata, so
    /// serialization via [`IPFix::to_be_bytes()`]
    /// assumes all fields are fixed-length.  Use
    /// [`Data::with_template_field_lengths`] when the template contains
    /// variable-length fields (field_length == 65535).
    pub fn new(fields: Vec<IPFixFlowRecord>) -> Self {
        debug_assert!(
            !fields.iter().any(|record| record
                .iter()
                .any(|(_, v)| matches!(v, FieldValue::Vec(b) if b.len() > 254))),
            "Data::new() should not be used with fields that may need variable-length \
             encoding; use Data::with_template_field_lengths() instead"
        );
        Self {
            fields,
            padding: vec![],
            template_field_lengths: vec![],
        }
    }

    /// Returns `true` if this data record has variable-length field metadata.
    pub fn has_varlen_metadata(&self) -> bool {
        !self.template_field_lengths.is_empty()
    }

    /// Creates a new Data instance with explicit template field lengths.
    ///
    /// Required for correct round-trip serialization when the template
    /// contains variable-length fields (RFC 7011, field_length == 65535).
    /// Each entry in `template_field_lengths` corresponds to the template
    /// field at the same index; entries with value 65535 cause an RFC 7011
    /// variable-length prefix to be emitted during serialization.
    ///
    /// # Errors
    ///
    /// Returns an error if `template_field_lengths` is non-empty and its
    /// length does not match the number of fields in the first record.
    pub fn with_template_field_lengths(
        fields: Vec<IPFixFlowRecord>,
        template_field_lengths: Vec<u16>,
    ) -> Result<Self, String> {
        if !fields.is_empty() && !template_field_lengths.is_empty() {
            let record_len = fields[0].len();
            if template_field_lengths.len() != record_len {
                return Err(format!(
                    "template_field_lengths length ({}) must match record field count ({})",
                    template_field_lengths.len(),
                    record_len,
                ));
            }
        }
        Ok(Self {
            fields,
            padding: vec![],
            template_field_lengths,
        })
    }
}

/// Parsed IPFIX options data records decoded using an IPFIX options template.
#[derive(Debug, Clone, Serialize, Nom)]
#[nom(ExtraArgs(template: &OptionsTemplate))]
pub struct OptionsData {
    #[nom(
        ErrorIf = "template.get_fields().is_empty() ",
        Parse = "{ |i| FieldParser::parse::<OptionsTemplate>(i, template, crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET) }"
    )]
    pub fields: Vec<Vec<IPFixFieldPair>>,
    #[serde(skip_serializing)]
    pub padding: Vec<u8>,
    /// Original template field lengths, used to emit RFC 7011 variable-length
    /// prefixes during serialization.  Not included in equality comparisons.
    /// Only populated when the template contains variable-length fields.
    #[serde(skip_serializing)]
    #[nom(Value({
        let fields = template.get_fields();
        if fields.iter().any(|f| f.field_length == 65535) {
            fields.iter().map(|f| f.field_length).collect::<Vec<u16>>()
        } else {
            Vec::new()
        }
    }))]
    pub(crate) template_field_lengths: Vec<u16>,
}

impl PartialEq for OptionsData {
    fn eq(&self, other: &Self) -> bool {
        self.fields == other.fields && self.padding == other.padding
    }
}

impl OptionsData {
    /// Creates a new OptionsData instance with the given fields.
    pub fn new(fields: Vec<Vec<IPFixFieldPair>>) -> Self {
        Self {
            fields,
            padding: vec![],
            template_field_lengths: vec![],
        }
    }

    /// Creates a new OptionsData instance with explicit template field lengths.
    ///
    /// # Errors
    ///
    /// Returns an error if `template_field_lengths` is non-empty and its
    /// length does not match the number of fields in the first record.
    pub fn with_template_field_lengths(
        fields: Vec<Vec<IPFixFieldPair>>,
        template_field_lengths: Vec<u16>,
    ) -> Result<Self, String> {
        if !fields.is_empty() && !template_field_lengths.is_empty() {
            let record_len = fields[0].len();
            if template_field_lengths.len() != record_len {
                return Err(format!(
                    "template_field_lengths length ({}) must match record field count ({})",
                    template_field_lengths.len(),
                    record_len,
                ));
            }
        }
        Ok(Self {
            fields,
            padding: vec![],
            template_field_lengths,
        })
    }
}

/// An IPFIX options template definition (RFC 7011 Section 3.4.2.2).
#[derive(Debug, Default, PartialEq, Eq, Clone, Serialize, Nom)]
pub struct OptionsTemplate {
    pub template_id: u16,
    pub field_count: u16,
    pub scope_field_count: u16,
    #[nom(
        PreExec = "let combined_count = usize::from(field_count);",
        Parse = "count(TemplateField::parse, combined_count)"
    )]
    pub fields: Vec<TemplateField>,
}

/// An IPFIX template definition (RFC 7011 Section 3.4.1) that describes data record layout.
#[derive(Debug, PartialEq, Eq, Clone, Serialize, Nom, Default)]
pub struct Template {
    pub template_id: u16,
    pub field_count: u16,
    #[nom(Count = "field_count")]
    pub fields: Vec<TemplateField>,
}

/// A single field definition within an IPFIX template, with optional enterprise number support.
#[derive(Debug, PartialEq, Eq, Clone, Serialize, Nom)]
pub struct TemplateField {
    #[nom(
        PostExec = "let (field_type_number, is_enterprise) = if field_type_number > 32767 {
                        (field_type_number & 0x7FFF, true)
                     } else { (field_type_number, false) };"
    )]
    pub field_type_number: u16,
    pub field_length: u16,
    #[nom(Cond = "is_enterprise")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enterprise_number: Option<u32>,
    #[nom(Value(IPFixField::new(field_type_number, enterprise_number)))]
    pub field_type: IPFixField,
}

/// Shared interface for IPFIX `Template` and `OptionsTemplate`, providing
/// field access and validation against parser configuration limits.
pub(crate) trait CommonTemplate {
    fn get_fields(&self) -> &[TemplateField];
    fn get_field_count(&self) -> u16;
    fn get_scope_field_count(&self) -> Option<u16> {
        None
    }

    fn is_valid(&self, parser: &IPFixParser) -> bool {
        self.is_valid_with_limits(parser.max_field_count, parser.max_template_total_size)
    }

    /// Validation against numeric limits, independent of parser type. Used
    /// by the secondary-store read-through path to avoid re-borrowing the
    /// whole `&IPFixParser` (which would conflict with the borrow held on
    /// `self.template_store`).
    fn is_valid_with_limits(
        &self,
        max_field_count: usize,
        max_template_total_size: usize,
    ) -> bool {
        // Check field count doesn't exceed maximum
        if usize::from(self.get_field_count()) > max_field_count {
            return false;
        }
        // Check scope field count if applicable (RFC 7011 Section 3.4.2.2:
        // at least one scope field AND at least one non-scope field required)
        if let Some(scope_count) = self.get_scope_field_count()
            && (scope_count == 0 || scope_count >= self.get_field_count())
        {
            return false;
        }
        // Check fields are not empty and no field has zero length
        // (field_length=65535 is the RFC 7011 variable-length sentinel, which is valid)
        if self.get_fields().is_empty() || self.get_fields().iter().any(|f| f.field_length == 0)
        {
            return false;
        }

        // Check total size limit (skip variable-length sentinel 65535,
        // which is an RFC 7011 marker, not an actual size)
        let total_size: usize = self
            .get_fields()
            .iter()
            .filter(|f| f.field_length != 65535)
            .fold(0, |acc, f| acc.saturating_add(usize::from(f.field_length)));
        if total_size > max_template_total_size {
            return false;
        }

        // Check for duplicate field IDs within scope and option fields separately.
        // RFC 7011 Section 3.4.2.2 allows a scope field and an option field to
        // share the same (field_type_number, enterprise_number) — they live in
        // different conceptual arrays.  For regular Templates (no scope fields),
        // this degenerates to a single-pass check over all fields.
        let scope_count = self.get_scope_field_count().map(usize::from).unwrap_or(0);
        let fields = self.get_fields();

        let mut seen = std::collections::HashSet::with_capacity(fields.len());
        // Check scope fields for duplicates among themselves
        for field in fields.iter().take(scope_count) {
            let key = (field.field_type_number, field.enterprise_number);
            if !seen.insert(key) {
                return false;
            }
        }
        // Check option fields for duplicates among themselves
        seen.clear();
        for field in fields.iter().skip(scope_count) {
            let key = (field.field_type_number, field.enterprise_number);
            if !seen.insert(key) {
                return false;
            }
        }

        true
    }
}

impl CommonTemplate for Template {
    fn get_fields(&self) -> &[TemplateField] {
        &self.fields
    }

    fn get_field_count(&self) -> u16 {
        self.field_count
    }
}

impl CommonTemplate for OptionsTemplate {
    fn get_fields(&self) -> &[TemplateField] {
        &self.fields
    }

    fn get_field_count(&self) -> u16 {
        self.field_count
    }

    fn get_scope_field_count(&self) -> Option<u16> {
        Some(self.scope_field_count)
    }
}

pub(crate) struct FieldParser;

// Rust-idiomatic naming aliases (additive, non-breaking)

/// Alias for [`IPFix`] using Rust naming conventions.
pub type Ipfix = IPFix;

/// Alias for [`IPFixParser`] using Rust naming conventions.
pub type IpfixParser = IPFixParser;

/// Alias for [`IPFixFieldPair`] using Rust naming conventions.
pub type IpfixFieldPair = IPFixFieldPair;

/// Alias for [`IPFixFlowRecord`] using Rust naming conventions.
pub type IpfixFlowRecord = IPFixFlowRecord;
