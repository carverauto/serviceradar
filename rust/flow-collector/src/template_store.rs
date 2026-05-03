//! NATS JetStream KV-backed [`netflow_parser::TemplateStore`].
//!
//! `netflow_parser` exposes a synchronous trait so it can be plugged in from
//! anywhere in the parser hot path. `async_nats`, the NATS client we use
//! everywhere else in the flow collector, is async-only. This module bridges
//! the two via `tokio::task::block_in_place` + `Handle::block_on`, which is
//! safe under the multi-threaded tokio runtime the collector already runs
//! under (other workers keep serving while this one blocks on a NATS
//! round-trip).
//!
//! # Why this exists
//!
//! With multiple flow-collector replicas behind a UDP load balancer, each
//! replica needs to observe the templates that any other replica has
//! learned — otherwise a data record routed to a fresh pod is dropped or
//! queued for the template definition that already lives in another
//! replica's in-process cache. NATS KV gives us a shared template tier
//! that survives both pod restarts and per-source-affinity routing
//! decisions made above us.
//!
//! See `netflow_parser::template_store` for the read-through / write-through
//! protocol the parser implements on top of this trait.

use async_nats::jetstream::kv::Store;
use log::warn;
use netflow_parser::{TemplateKind, TemplateStore, TemplateStoreError, TemplateStoreKey};
use std::sync::Once;
use tokio::runtime::Handle;

/// `TemplateStore` impl backed by a NATS JetStream KV bucket.
///
/// One instance can be shared (via `Arc`) across all parser instances in the
/// process; the underlying NATS client is internally reference-counted and
/// thread-safe.
#[derive(Debug)]
pub struct NatsKvTemplateStore {
    kv: Store,
    /// Tokio runtime handle captured at construction so the synchronous
    /// `TemplateStore` methods can drive the async NATS client without
    /// requiring callers to be inside `Handle::current()`.
    handle: Handle,
}

impl NatsKvTemplateStore {
    /// Build a new store. Must be called from inside a tokio runtime —
    /// the `Handle` is captured at construction time.
    ///
    /// # Panics
    ///
    /// Panics if there is no current tokio runtime. In practice this is
    /// fine because the flow-collector creates the store from `main()`
    /// after `#[tokio::main]` has set up the runtime.
    pub fn new(kv: Store) -> Self {
        Self {
            kv,
            handle: Handle::current(),
        }
    }

    /// Render a [`TemplateStoreKey`] as a NATS KV key.
    ///
    /// NATS KV keys must consist of `[A-Za-z0-9._=/-]` and use `.` as a
    /// token separator. Our scope strings come from
    /// [`netflow_parser::AutoScopedParser`] and look like
    /// `"v9:10.0.0.1:2055/0"` (IPv4) or `"legacy:[fe80::1]:6343"` (IPv6),
    /// which contain `:`, `[`, `]` — characters NATS forbids. We
    /// replace any disallowed character with `_`. Scopes that come from
    /// `format!("{}:{}/{}", ...)` patterns can't collide after this
    /// substitution in practice because the surrounding tokens (`v9`,
    /// `ipfix`, `legacy`) and template-id suffix keep the structure
    /// distinct.
    ///
    /// Layout: `{safe_scope}.{kind_tag}.{template_id}`
    pub(crate) fn render_key(key: &TemplateStoreKey) -> String {
        let kind_tag = kind_tag(key.kind);
        let mut safe_scope = String::with_capacity(key.scope.len());
        for c in key.scope.chars() {
            match c {
                'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '=' => safe_scope.push(c),
                _ => safe_scope.push('_'),
            }
        }
        if safe_scope.is_empty() {
            safe_scope.push_str("default");
        }
        format!("{}.{}.{}", safe_scope, kind_tag, key.template_id)
    }
}

fn kind_tag(kind: TemplateKind) -> &'static str {
    // `TemplateKind` is marked `#[non_exhaustive]` upstream so this match
    // must have a wildcard. If a new variant ships in netflow_parser, the
    // build keeps working — entries land under "unk" so they're at least
    // grouped predictably — but we warn once on first sighting so an
    // operator has a chance to notice. Add a new explicit arm when
    // bumping the dep.
    match kind {
        TemplateKind::V9Data => "v9d",
        TemplateKind::V9Options => "v9o",
        TemplateKind::IpfixData => "ipd",
        TemplateKind::IpfixOptions => "ipo",
        TemplateKind::IpfixV9Data => "i9d",
        TemplateKind::IpfixV9Options => "i9o",
        _ => {
            static ONCE: Once = Once::new();
            ONCE.call_once(|| {
                warn!(
                    "Unknown TemplateKind variant {:?} from netflow_parser — bump the dep \
                     and add an explicit kind_tag arm; entries are landing under '.unk.'",
                    kind
                );
            });
            "unk"
        }
    }
}

impl TemplateStore for NatsKvTemplateStore {
    fn get(&self, key: &TemplateStoreKey) -> Result<Option<Vec<u8>>, TemplateStoreError> {
        let nats_key = Self::render_key(key);
        let kv = self.kv.clone();
        tokio::task::block_in_place(|| {
            self.handle.block_on(async move {
                match kv.get(&nats_key).await {
                    Ok(Some(bytes)) => Ok(Some(bytes.to_vec())),
                    Ok(None) => Ok(None),
                    Err(e) => Err(TemplateStoreError::Backend(Box::new(e))),
                }
            })
        })
    }

    fn put(&self, key: &TemplateStoreKey, value: &[u8]) -> Result<(), TemplateStoreError> {
        let nats_key = Self::render_key(key);
        let bytes = bytes::Bytes::copy_from_slice(value);
        let kv = self.kv.clone();
        tokio::task::block_in_place(|| {
            self.handle.block_on(async move {
                kv.put(&nats_key, bytes)
                    .await
                    .map(|_revision| ())
                    .map_err(|e| TemplateStoreError::Backend(Box::new(e)))
            })
        })
    }

    fn remove(&self, key: &TemplateStoreKey) -> Result<(), TemplateStoreError> {
        let nats_key = Self::render_key(key);
        let kv = self.kv.clone();
        tokio::task::block_in_place(|| {
            self.handle.block_on(async move {
                // `delete` is idempotent: removing an absent key is not an
                // error. Subsequent `get()` returns Ok(None), which the
                // parser treats as a normal cache miss.
                kv.delete(&nats_key)
                    .await
                    .map_err(|e| TemplateStoreError::Backend(Box::new(e)))
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn key(scope: &str, kind: TemplateKind, id: u16) -> TemplateStoreKey {
        TemplateStoreKey::new(Arc::<str>::from(scope), kind, id)
    }

    #[test]
    fn render_v9_per_source_scope_is_nats_safe() {
        let k = key("v9:10.0.0.1:2055/0", TemplateKind::V9Data, 256);
        let rendered = NatsKvTemplateStore::render_key(&k);
        assert_eq!(rendered, "v9_10_0_0_1_2055_0.v9d.256");
        // Round-trip through the NATS subject grammar: every char must be
        // alnum / dash / underscore / dot / equals / slash.
        assert!(
            rendered
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '=' | '/' | '.'))
        );
    }

    #[test]
    fn render_ipv6_scope_strips_brackets_and_colons() {
        let k = key("ipfix:[fe80::1]:4739/42", TemplateKind::IpfixData, 300);
        let rendered = NatsKvTemplateStore::render_key(&k);
        assert_eq!(rendered, "ipfix__fe80__1__4739_42.ipd.300");
        assert!(!rendered.contains([':', '[', ']']));
    }

    #[test]
    fn empty_scope_renders_as_default() {
        let k = key("", TemplateKind::V9Options, 257);
        let rendered = NatsKvTemplateStore::render_key(&k);
        assert_eq!(rendered, "default.v9o.257");
    }

    #[test]
    fn distinct_scopes_render_distinctly() {
        let a = key("v9:10.0.0.1:2055/0", TemplateKind::V9Data, 256);
        let b = key("v9:10.0.0.2:2055/0", TemplateKind::V9Data, 256);
        assert_ne!(
            NatsKvTemplateStore::render_key(&a),
            NatsKvTemplateStore::render_key(&b)
        );
    }

    #[test]
    fn distinct_kinds_render_distinctly() {
        let a = key("scope", TemplateKind::V9Data, 256);
        let b = key("scope", TemplateKind::V9Options, 256);
        let c = key("scope", TemplateKind::IpfixData, 256);
        assert_ne!(NatsKvTemplateStore::render_key(&a), NatsKvTemplateStore::render_key(&b));
        assert_ne!(NatsKvTemplateStore::render_key(&a), NatsKvTemplateStore::render_key(&c));
        assert_ne!(NatsKvTemplateStore::render_key(&b), NatsKvTemplateStore::render_key(&c));
    }
}
