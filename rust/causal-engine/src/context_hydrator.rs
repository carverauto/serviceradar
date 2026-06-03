//! Context hydration — the seam between data acquisition and reasoning.
//!
//! [`ContextStore`] is the trait the reasoner uses to obtain the current
//! `Context`. In V1 it is an in-process direct call; the trait preserves a
//! future hydrator/reasoner split (a gRPC/NATS implementation) without a
//! rewrite (add-causal-engine design.md, the `ContextStore` decision).

use async_trait::async_trait;

use crate::domain_model::Context;
use crate::error::Result;

/// Interface the reasoner uses to read the latest hydrated `Context`.
#[async_trait]
pub trait ContextStore: Send + Sync {
    /// Return the latest hydrated `Context` for a reasoning tick.
    async fn current_context(&self) -> Result<Context>;
}

/// V1 in-process hydrator.
///
/// TODO(1.2): own the three ingestion feeds —
///   1. `EmbeddedSrql` over CNPG (cold-start current state + on-demand
///      TimescaleDB continuous-aggregate queries + AGE topology via
///      `graph_cypher`);
///   2. a JetStream subscriber for live deltas on the existing causal subjects
///      (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, zen OCSF);
///   3. a JetStream subscriber for the app-level `cdc.platform.<table>`
///      state-change feed (Phase 0, Decision 1).
///
/// Single-point id validation at ingestion (reject/normalize non-`sr:` ids);
/// never consume TimescaleDB hypertable CDC.
#[derive(Default)]
pub struct ContextHydrator {
    // TODO(1.2): EmbeddedSrql handle, JetStream subscriber, delta buffer.
}

impl ContextHydrator {
    /// Construct a hydrator. TODO(1.2): take `Config` + open CNPG/NATS.
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl ContextStore for ContextHydrator {
    async fn current_context(&self) -> Result<Context> {
        // TODO(1.2): hydrate from EmbeddedSrql and merge JetStream + cdc deltas.
        Ok(Context::default())
    }
}
