//! `causal-engine` — ServiceRadar's DeepCausality causal engine.
//!
//! OpenSpec change: `add-causal-engine`. This is the single-pod fused V1 service:
//! a [`context_hydrator`] feeds a DeepCausality `Context` from CNPG (via
//! `EmbeddedSrql`), JetStream deltas, and the `signals.state.<table>` app-level
//! state-change feed; a [`reasoner`] evaluates causaloids C1–C13 over an
//! `ultragraph` `CsmGraph`; and an [`emitter`] publishes verdicts on
//! `signals.causal.predictions`, which the existing `CausalSignals` processor
//! normalizes into `ocsf_events` — re-entering `StatefulAlertEngine` (the
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
pub mod snapshot;
pub mod subscriber;

pub use config::Config;
pub use context_hydrator::{ContextHydrator, ContextStore};
pub use delta::{apply_delta, parse_state_change, StateChangeDelta};
pub use domain_model::{Context, Device, EntityId, Service};
pub use error::{CausalEngineError, Result};
pub use reasoner::{Classification, Reasoner, Verdict};
