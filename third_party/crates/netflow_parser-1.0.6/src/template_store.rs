//! Pluggable secondary-tier template storage.
//!
//! NetFlow v9 and IPFIX exporters announce *templates* describing the layout
//! of subsequent data records. The parser caches these templates in an
//! in-process LRU; without a template, data records cannot be decoded.
//!
//! For multi-instance deployments (horizontally scaled flow collectors behind
//! a UDP load balancer, for example) every parser instance must observe the
//! same templates as the exporters that route to it. Otherwise a data record
//! can land on a replica that has never seen the corresponding template and
//! must be queued or dropped.
//!
//! [`TemplateStore`] is the extension point that solves this. When configured
//! via [`NetflowParserBuilder::with_template_store`](crate::NetflowParserBuilder::with_template_store):
//!
//! 1. On every successful template insert the parser **writes through** to the
//!    store, persisting the template in a small custom binary wire format.
//! 2. On every cache **miss** the parser consults the store. If the store
//!    returns a payload, the parser decodes it, repopulates its in-process
//!    LRU, and continues parsing the data record.
//! 3. On LRU eviction or explicit clear/withdrawal the parser issues a best
//!    effort `remove` to keep the store from accumulating stale entries.
//!
//! The store sees opaque `Vec<u8>` payloads and a structured key — it does
//! not need to understand the wire format. This keeps the trait surface tiny
//! and lets implementations target arbitrary backends (Redis, NATS KV,
//! DynamoDB, an in-memory map for tests, ...).
//!
//! # Scoping
//!
//! Templates are scoped per exporter. The parser carries a `scope: String`
//! that is included in every [`TemplateStoreKey`]. For single-source
//! deployments callers may leave this empty (the default). For multi-source
//! deployments [`AutoScopedParser`](crate::AutoScopedParser) automatically
//! sets the scope to the source `SocketAddr` of each per-source parser, so
//! template ID collisions between different exporters are isolated by key.
//!
//! # Threading
//!
//! Implementations are wrapped in `Arc<dyn TemplateStore>` and must be
//! `Send + Sync`. Parsers acquire only shared references to the store, so
//! implementations should use interior mutability (mutex, atomic, channel,
//! etc.) for any internal state.
//!
//! # Reference implementation
//!
//! [`InMemoryTemplateStore`] is a `Mutex<HashMap>`-backed reference impl
//! suitable for tests and single-process experiments. Production deployments
//! should provide their own backend.
//!
//! # Wire format & upgrades
//!
//! Templates are encoded with a small versioned binary format whose first
//! byte is `WIRE_VERSION` (currently `1`). The parser rejects payloads with
//! an unrecognized version: a [`TemplateStoreError::Codec`] is recorded in
//! metrics ([`crate::CacheMetrics::template_store_codec_errors`]), the
//! offending key is removed from the store, and the parser falls back to
//! treating the slot as a cache miss until the exporter re-announces the
//! template.
//!
//! When this crate ships a wire-format change, existing entries written by
//! older parser versions become unreadable. Rolling-upgrade strategies:
//!
//! * Drain the secondary store before deploying the new parser version
//!   (template caches will rebuild from the next exporter announce).
//! * Or namespace your scope with the parser version
//!   ([`NetflowParserBuilder::with_template_store_scope`](
//!   crate::NetflowParserBuilder::with_template_store_scope))
//!   so old- and new-version entries do not collide.
//!
//! Either way, monitor `template_store_codec_errors` after the upgrade — a
//! sustained non-zero rate indicates stale entries that the parser is
//! discarding on read.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Identifies which of the parser's template caches an entry belongs to.
///
/// V9 and IPFIX maintain separate template and options-template caches.
/// IPFIX additionally accepts V9-style templates embedded in IPFIX messages,
/// which are stored in their own caches. Each variant maps to exactly one
/// internal cache so that store entries can be round-tripped to the right
/// place on read-through.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TemplateKind {
    /// NetFlow v9 data template (decoded with the v9 parser).
    V9Data,
    /// NetFlow v9 options template.
    V9Options,
    /// IPFIX data template.
    IpfixData,
    /// IPFIX options template.
    IpfixOptions,
    /// V9-style data template embedded in an IPFIX message.
    IpfixV9Data,
    /// V9-style options template embedded in an IPFIX message.
    IpfixV9Options,
}

/// Composite key identifying a template entry in a [`TemplateStore`].
///
/// Implementations may format the key however they like (e.g. as a single
/// string `"{scope}/{kind}/{template_id}"` for Redis, or a structured object
/// for NATS KV) — the only requirement is that distinct keys must round-trip
/// independently.
///
/// `scope` is stored as `Arc<str>` so the parser can share the same string
/// across every store key it constructs without per-call heap allocations.
/// Implementations that need a `&str` can dereference (`&*key.scope`);
/// callers constructing keys can pass `&str`, `String`, or an existing
/// `Arc<str>`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TemplateStoreKey {
    /// Per-exporter scope. Empty when the parser is unscoped (single source).
    /// `AutoScopedParser` populates this with the source identity.
    pub scope: Arc<str>,
    /// Which template cache the entry belongs to.
    pub kind: TemplateKind,
    /// The template ID announced by the exporter.
    pub template_id: u16,
}

impl TemplateStoreKey {
    /// Convenience constructor.
    pub fn new(scope: impl Into<Arc<str>>, kind: TemplateKind, template_id: u16) -> Self {
        Self {
            scope: scope.into(),
            kind,
            template_id,
        }
    }
}

/// Errors returned by [`TemplateStore`] implementations.
#[derive(Debug)]
pub enum TemplateStoreError {
    /// Underlying backend failure (network, IO, serialization in the backend, ...).
    Backend(Box<dyn std::error::Error + Send + Sync>),
    /// The store returned a payload the parser could not decode.
    /// Typically indicates a wire-format version mismatch or corruption.
    Codec(String),
}

impl std::fmt::Display for TemplateStoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TemplateStoreError::Backend(e) => write!(f, "template store backend error: {}", e),
            TemplateStoreError::Codec(msg) => {
                write!(f, "template store codec error: {}", msg)
            }
        }
    }
}

impl std::error::Error for TemplateStoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            TemplateStoreError::Backend(e) => Some(e.as_ref()),
            TemplateStoreError::Codec(_) => None,
        }
    }
}

/// Pluggable backend for sharing parsed templates across parser instances.
///
/// See the [module docs](self) for the full read-through / write-through
/// protocol the parser implements on top of this trait.
///
/// # Contract
///
/// * `get` returns `Ok(None)` when the key is absent. Errors are reserved for
///   backend-level failures.
/// * `put` is best-effort from the parser's perspective: a returned error is
///   logged via the parser's metrics but does not abort packet parsing.
/// * `remove` must be idempotent — the parser may call it for keys that are
///   already absent.
///
/// # Threading
///
/// Implementations are wrapped in `Arc<dyn TemplateStore>` and must be both
/// `Send` and `Sync`. The trait takes `&self` everywhere; implementations
/// that need internal mutation should use `Mutex`, `RwLock`, or atomics.
pub trait TemplateStore: Send + Sync + std::fmt::Debug {
    /// Fetch a serialized template payload by key.
    /// Returns `Ok(None)` when the key is absent (not an error).
    fn get(&self, key: &TemplateStoreKey) -> Result<Option<Vec<u8>>, TemplateStoreError>;

    /// Persist a serialized template payload. Overwrites any existing value
    /// for the same key.
    fn put(&self, key: &TemplateStoreKey, value: &[u8]) -> Result<(), TemplateStoreError>;

    /// Remove the entry for `key`. Must be idempotent for absent keys.
    fn remove(&self, key: &TemplateStoreKey) -> Result<(), TemplateStoreError>;
}

/// Reference [`TemplateStore`] backed by a `Mutex<HashMap>`.
///
/// Suitable for tests and single-process experiments. Sharing one of these
/// across multiple parser instances within the same process is functionally
/// equivalent to enlarging the in-process LRU caches; the value of the
/// extension point is realized when the store is backed by an out-of-process
/// system such as Redis or NATS KV.
///
/// # Panics
///
/// Methods panic if the inner `Mutex` is poisoned (which only happens after
/// a panic in another thread holding the lock). Production stores backed
/// by your own backend should make their own choice — returning an error
/// via [`TemplateStoreError::Backend`] is generally safer than panicking.
#[derive(Debug, Default)]
pub struct InMemoryTemplateStore {
    inner: Mutex<HashMap<TemplateStoreKey, Vec<u8>>>,
}

impl InMemoryTemplateStore {
    /// Create an empty store.
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of entries currently held.
    pub fn len(&self) -> usize {
        self.inner.lock().expect("poisoned").len()
    }

    /// Whether the store is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl TemplateStore for InMemoryTemplateStore {
    fn get(&self, key: &TemplateStoreKey) -> Result<Option<Vec<u8>>, TemplateStoreError> {
        Ok(self.inner.lock().expect("poisoned").get(key).cloned())
    }

    fn put(&self, key: &TemplateStoreKey, value: &[u8]) -> Result<(), TemplateStoreError> {
        self.inner
            .lock()
            .expect("poisoned")
            .insert(key.clone(), value.to_vec());
        Ok(())
    }

    fn remove(&self, key: &TemplateStoreKey) -> Result<(), TemplateStoreError> {
        self.inner.lock().expect("poisoned").remove(key);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Wire format
// ---------------------------------------------------------------------------
//
// Templates are encoded using a small versioned binary format. The first byte
// is a version tag (currently `WIRE_VERSION = 1`); subsequent layout depends
// on `TemplateKind` and is documented at each `encode_*` / `decode_*` site.
//
// The format is intentionally minimal: it carries only the fields the parser
// needs to reconstruct an in-memory `Template` / `OptionsTemplate`, not the
// derived lookup-table values which are recomputed from the field-type
// numbers. This keeps payloads small (typically <100 bytes) and avoids
// pulling in serde_json or another runtime serializer.

pub(crate) const WIRE_VERSION: u8 = 1;

use crate::variable_versions::ipfix::lookup::IPFixField;
use crate::variable_versions::ipfix::{
    OptionsTemplate as IpfixOptionsTemplate, Template as IpfixTemplate,
    TemplateField as IpfixTemplateField,
};
use crate::variable_versions::v9::lookup::{ScopeFieldType, V9Field};
use crate::variable_versions::v9::{
    OptionsTemplate as V9OptionsTemplate, OptionsTemplateScopeField, Template as V9Template,
    TemplateField as V9TemplateField,
};

/// Encode a V9 data template into the wire format.
///
/// Layout: `[version: u8][template_id: u16][field_count: u16][fields]`
/// where each field is `[field_type_number: u16][field_length: u16]`.
pub(crate) fn encode_v9_template(t: &V9Template) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + t.fields.len() * 4);
    out.push(WIRE_VERSION);
    out.extend_from_slice(&t.template_id.to_be_bytes());
    out.extend_from_slice(&t.field_count.to_be_bytes());
    for f in &t.fields {
        out.extend_from_slice(&f.field_type_number.to_be_bytes());
        out.extend_from_slice(&f.field_length.to_be_bytes());
    }
    out
}

pub(crate) fn decode_v9_template(bytes: &[u8]) -> Result<V9Template, TemplateStoreError> {
    let mut r = WireReader::new(bytes);
    r.expect_version()?;
    let template_id = r.u16()?;
    let field_count = r.u16()?;
    let mut fields = Vec::with_capacity(usize::from(field_count));
    for _ in 0..field_count {
        let field_type_number = r.u16()?;
        let field_length = r.u16()?;
        fields.push(V9TemplateField {
            field_type_number,
            field_type: V9Field::from(field_type_number),
            field_length,
        });
    }
    Ok(V9Template {
        template_id,
        field_count,
        fields,
    })
}

/// Encode a V9 options template.
///
/// Layout: `[version: u8][template_id: u16][options_scope_length: u16]
///          [options_length: u16][scope_fields][option_fields]`
/// where each `scope_fields` entry is `[field_type_number: u16][field_length: u16]`
/// and each `option_fields` entry is `[field_type_number: u16][field_length: u16]`.
pub(crate) fn encode_v9_options_template(t: &V9OptionsTemplate) -> Vec<u8> {
    let mut out = Vec::with_capacity(7 + t.scope_fields.len() * 4 + t.option_fields.len() * 4);
    out.push(WIRE_VERSION);
    out.extend_from_slice(&t.template_id.to_be_bytes());
    out.extend_from_slice(&t.options_scope_length.to_be_bytes());
    out.extend_from_slice(&t.options_length.to_be_bytes());
    for f in &t.scope_fields {
        out.extend_from_slice(&f.field_type_number.to_be_bytes());
        out.extend_from_slice(&f.field_length.to_be_bytes());
    }
    for f in &t.option_fields {
        out.extend_from_slice(&f.field_type_number.to_be_bytes());
        out.extend_from_slice(&f.field_length.to_be_bytes());
    }
    out
}

pub(crate) fn decode_v9_options_template(
    bytes: &[u8],
) -> Result<V9OptionsTemplate, TemplateStoreError> {
    let mut r = WireReader::new(bytes);
    r.expect_version()?;
    let template_id = r.u16()?;
    let options_scope_length = r.u16()?;
    let options_length = r.u16()?;
    // Each scope/option field occupies 4 bytes (u16 type + u16 length); a
    // length not divisible by 4 means the payload is corrupted. The live
    // parse path enforces the same rule via `OptionsTemplate::is_valid`.
    if !options_scope_length.is_multiple_of(4) || !options_length.is_multiple_of(4) {
        return Err(TemplateStoreError::Codec(format!(
            "v9 options template length not aligned to 4: scope={} options={}",
            options_scope_length, options_length
        )));
    }
    let scope_count = usize::from(options_scope_length / 4);
    let option_count = usize::from(options_length / 4);
    let mut scope_fields = Vec::with_capacity(scope_count);
    for _ in 0..scope_count {
        let field_type_number = r.u16()?;
        let field_length = r.u16()?;
        scope_fields.push(OptionsTemplateScopeField {
            field_type_number,
            field_type: ScopeFieldType::from(field_type_number),
            field_length,
        });
    }
    let mut option_fields = Vec::with_capacity(option_count);
    for _ in 0..option_count {
        let field_type_number = r.u16()?;
        let field_length = r.u16()?;
        option_fields.push(V9TemplateField {
            field_type_number,
            field_type: V9Field::from(field_type_number),
            field_length,
        });
    }
    Ok(V9OptionsTemplate {
        template_id,
        options_scope_length,
        options_length,
        scope_fields,
        option_fields,
    })
}

/// Encode an IPFIX template.
///
/// Layout: `[version: u8][template_id: u16][field_count: u16][fields]` where
/// each field is `[field_type_number: u16][field_length: u16]
/// [enterprise_present: u8][enterprise_number: u32?]`. The trailing u32 is
/// only present when `enterprise_present == 1`.
pub(crate) fn encode_ipfix_template(t: &IpfixTemplate) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + t.fields.len() * 9);
    out.push(WIRE_VERSION);
    out.extend_from_slice(&t.template_id.to_be_bytes());
    out.extend_from_slice(&t.field_count.to_be_bytes());
    for f in &t.fields {
        encode_ipfix_field(&mut out, f);
    }
    out
}

pub(crate) fn decode_ipfix_template(bytes: &[u8]) -> Result<IpfixTemplate, TemplateStoreError> {
    let mut r = WireReader::new(bytes);
    r.expect_version()?;
    let template_id = r.u16()?;
    let field_count = r.u16()?;
    let mut fields = Vec::with_capacity(usize::from(field_count));
    for _ in 0..field_count {
        fields.push(decode_ipfix_field(&mut r)?);
    }
    Ok(IpfixTemplate {
        template_id,
        field_count,
        fields,
    })
}

/// Encode an IPFIX options template.
///
/// Layout: `[version: u8][template_id: u16][field_count: u16]
///          [scope_field_count: u16][fields]` where fields are encoded as in
/// `encode_ipfix_template`.
pub(crate) fn encode_ipfix_options_template(t: &IpfixOptionsTemplate) -> Vec<u8> {
    let mut out = Vec::with_capacity(7 + t.fields.len() * 9);
    out.push(WIRE_VERSION);
    out.extend_from_slice(&t.template_id.to_be_bytes());
    out.extend_from_slice(&t.field_count.to_be_bytes());
    out.extend_from_slice(&t.scope_field_count.to_be_bytes());
    for f in &t.fields {
        encode_ipfix_field(&mut out, f);
    }
    out
}

pub(crate) fn decode_ipfix_options_template(
    bytes: &[u8],
) -> Result<IpfixOptionsTemplate, TemplateStoreError> {
    let mut r = WireReader::new(bytes);
    r.expect_version()?;
    let template_id = r.u16()?;
    let field_count = r.u16()?;
    let scope_field_count = r.u16()?;
    let mut fields = Vec::with_capacity(usize::from(field_count));
    for _ in 0..field_count {
        fields.push(decode_ipfix_field(&mut r)?);
    }
    Ok(IpfixOptionsTemplate {
        template_id,
        field_count,
        scope_field_count,
        fields,
    })
}

fn encode_ipfix_field(out: &mut Vec<u8>, f: &IpfixTemplateField) {
    out.extend_from_slice(&f.field_type_number.to_be_bytes());
    out.extend_from_slice(&f.field_length.to_be_bytes());
    match f.enterprise_number {
        Some(en) => {
            out.push(1);
            out.extend_from_slice(&en.to_be_bytes());
        }
        None => out.push(0),
    }
}

fn decode_ipfix_field(
    r: &mut WireReader<'_>,
) -> Result<IpfixTemplateField, TemplateStoreError> {
    let field_type_number = r.u16()?;
    let field_length = r.u16()?;
    let enterprise_present = r.u8()?;
    let enterprise_number = match enterprise_present {
        0 => None,
        1 => Some(r.u32()?),
        other => {
            return Err(TemplateStoreError::Codec(format!(
                "invalid enterprise flag: {}",
                other
            )));
        }
    };
    Ok(IpfixTemplateField {
        field_type_number,
        field_length,
        enterprise_number,
        field_type: IPFixField::new(field_type_number, enterprise_number),
    })
}

struct WireReader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> WireReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn expect_version(&mut self) -> Result<(), TemplateStoreError> {
        let v = self.u8()?;
        if v != WIRE_VERSION {
            return Err(TemplateStoreError::Codec(format!(
                "unsupported wire version: {} (expected {})",
                v, WIRE_VERSION
            )));
        }
        Ok(())
    }

    fn u8(&mut self) -> Result<u8, TemplateStoreError> {
        let bytes = self.take(1)?;
        Ok(bytes[0])
    }

    fn u16(&mut self) -> Result<u16, TemplateStoreError> {
        let bytes = self.take(2)?;
        Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
    }

    fn u32(&mut self) -> Result<u32, TemplateStoreError> {
        let bytes = self.take(4)?;
        Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], TemplateStoreError> {
        if self.pos + n > self.buf.len() {
            return Err(TemplateStoreError::Codec(format!(
                "unexpected end of payload at offset {} (need {} more)",
                self.pos, n
            )));
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_round_trip() {
        let store = InMemoryTemplateStore::new();
        let key = TemplateStoreKey::new("1.2.3.4:2055", TemplateKind::V9Data, 256);
        assert!(store.get(&key).unwrap().is_none());
        store.put(&key, b"hello").unwrap();
        assert_eq!(store.get(&key).unwrap().as_deref(), Some(&b"hello"[..]));
        assert_eq!(store.len(), 1);
        store.remove(&key).unwrap();
        assert!(store.get(&key).unwrap().is_none());
        assert!(store.is_empty());
    }

    #[test]
    fn v9_template_wire_round_trip() {
        let original = V9Template {
            template_id: 256,
            field_count: 3,
            fields: vec![
                V9TemplateField {
                    field_type_number: 8,
                    field_type: V9Field::from(8),
                    field_length: 4,
                },
                V9TemplateField {
                    field_type_number: 12,
                    field_type: V9Field::from(12),
                    field_length: 4,
                },
                V9TemplateField {
                    field_type_number: 1,
                    field_type: V9Field::from(1),
                    field_length: 8,
                },
            ],
        };
        let bytes = encode_v9_template(&original);
        let decoded = decode_v9_template(&bytes).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn ipfix_template_wire_round_trip_with_enterprise() {
        let original = IpfixTemplate {
            template_id: 300,
            field_count: 2,
            fields: vec![
                IpfixTemplateField {
                    field_type_number: 8,
                    field_length: 4,
                    enterprise_number: None,
                    field_type: IPFixField::new(8, None),
                },
                IpfixTemplateField {
                    field_type_number: 1,
                    field_length: 8,
                    enterprise_number: Some(9),
                    field_type: IPFixField::new(1, Some(9)),
                },
            ],
        };
        let bytes = encode_ipfix_template(&original);
        let decoded = decode_ipfix_template(&bytes).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn rejects_bad_version() {
        let bad = vec![99u8, 0, 0, 0, 0];
        let err = decode_v9_template(&bad).unwrap_err();
        assert!(matches!(err, TemplateStoreError::Codec(_)));
    }

    #[test]
    fn rejects_truncated_payload() {
        let bytes = vec![WIRE_VERSION, 0]; // declares version, missing rest
        let err = decode_v9_template(&bytes).unwrap_err();
        assert!(matches!(err, TemplateStoreError::Codec(_)));
    }
}
