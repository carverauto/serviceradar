//! `correlation-engine` — ServiceRadar's deterministic dependency / expert-reasoning engine.
//!
//! Honest framing: this is NOT causal inference (no SCM, do-calculus, counterfactual,
//! or intervention). It is a deterministic expert system — a fixed set of hand-coded
//! rules (C1–C13) plus topology graph algorithms (centrality / reachability /
//! articulation points / bridges). It is hosted on DeepCausality types (the "causaloids"
//! are largely identity nodes and the graph is queried with plain `ultragraph`
//! algorithms), but the reasoning is rule + dependency-graph logic.
//!
//! OpenSpec change: `add-causal-engine`. This is the single-pod fused V1 service:
//! a [`context_hydrator`] feeds a `Context` from CNPG (via `EmbeddedSrql`), JetStream
//! deltas, and the `signals.state.<table>` app-level state-change feed; a [`reasoner`]
//! evaluates the C1–C13 rules over an `ultragraph` `CsmGraph`; and an [`emitter`]
//! publishes verdicts on `signals.analytics.predictions`, which the `AnalyticsSignals`
//! processor normalizes into `ocsf_events` — re-entering `StatefulAlertEngine` (the
//! automation loop) and the God-View renderer.
//!
//! The crate is scaffolded incrementally; modules carry `TODO(<task>)` markers
//! referencing `openspec/changes/add-causal-engine/tasks.md`.

pub mod config;
pub mod context_hydrator;
pub mod delta;
pub mod domain_model;
pub mod emitter;
pub mod error;
pub mod god_view;
pub mod graph;
pub mod nats;
pub mod reasoner;
pub mod signal_evidence;
pub mod snapshot;
pub mod subscriber;

pub use config::Config;
pub use context_hydrator::{ContextHydrator, ContextStore};
pub use delta::{StateChangeDelta, apply_delta, parse_state_change};
pub use domain_model::{Context, Device, EntityId, Service};
pub use error::{CorrelationEngineError, Result};
pub use reasoner::{Classification, Reasoner, Verdict};

#[cfg(test)]
mod metric_proto_contract_tests {
    use serviceradar_metric_proto::pb::{
        Metric, MetricBatch, MetricKind, MetricPoint, MetricResource, MetricTemporality,
    };

    #[test]
    fn correlation_engine_links_against_canonical_metric_envelope_prost_types() {
        let batch = MetricBatch {
            schema_version: "serviceradar.metric.v1".to_owned(),
            resource: Some(MetricResource {
                agent_id: "agent-1".to_owned(),
                gateway_id: "gateway-1".to_owned(),
                ..Default::default()
            }),
            metrics: vec![Metric {
                name: "ifHCInOctets".to_owned(),
                metric_type: "snmp".to_owned(),
                kind: MetricKind::Sum as i32,
                temporality: MetricTemporality::Cumulative as i32,
                is_monotonic: true,
                points: vec![MetricPoint {
                    value: 128.0,
                    raw_value: "128".to_owned(),
                    observed_at_unix_nano: 1_765_500_000_000_000_000,
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };

        assert_eq!(batch.schema_version, "serviceradar.metric.v1");
        assert_eq!(batch.resource.as_ref().unwrap().agent_id, "agent-1");
        assert_eq!(batch.metrics[0].kind, MetricKind::Sum as i32);
        assert_eq!(
            batch.metrics[0].temporality,
            MetricTemporality::Cumulative as i32
        );
        assert!(batch.metrics[0].is_monotonic);
        assert_eq!(batch.metrics[0].points[0].raw_value, "128");
    }
}
