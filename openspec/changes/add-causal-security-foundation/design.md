# Design — add-causal-security-foundation

## Context

This is Phase 0 of repositioning ServiceRadar's causal engine toward cross-domain
intrusion detection (NDR/XDR). The design note
(`openspec/notes/sr-causal-engine.md`, §1, §2, §4.1–4.3, §5, §8.1, §9) frames the
engine as three hard-bounded layers — L1 data integration, L2 context (the
DeepCausality world model), L3 causal reasoning — that each evolve independently.

This milestone EXTENDS the settled `add-causal-engine` chassis, which already
defines the fused single-pod engine, the three ingestion feeds, the
`signals.analytics.predictions.>` → `AnalyticsSignals` emission path, the
`god_view_nif` demotion, and the reliability causaloid catalog (C1–C13). This
change does NOT redefine any of that. It refines the chassis's single-crate
modules (`context_hydrator`/`domain_model`/`reasoner`/`emitter`/`snapshot`) into a
flat `rust/causal-*` crate family for stronger isolation, and it adds the
security-specific reasoning primitives: the `SecVerdict` lattice, the corroboration
fusion contract, and the stable `Observation` model.

Constraints inherited from the chassis and verified against the repo:

- Prediction subject is `signals.analytics.predictions.>` → processor
  `AnalyticsSignals`; `signals.causal.*`/`CausalSignals` are removed legacy and
  MUST NOT be used.
- State feed is the app-level `signals.state.<table>` publisher
  (`StateChangePublisher`, gated by `STATE_CHANGE_EVENTS_ENABLED`), NOT pgoutput
  CDC/logical replication.
- Entity IDs are canonical `sr:`-prefixed (`RuntimeGraph.canonical_runtime_id/1`);
  the AGE graph is `platform_graph`.
- Rust crates are flat `rust/causal-*` dirs as root-workspace members (mirror
  `rust/anomaly-*`), no `crates/` subfolder, one shared lockfile.

## Goals / Non-Goals

- Goals:
  - Establish `SecVerdict` as a lawful, order-invariant `Verdict` lattice so
    later kill-chain graph reasoning composes correctly.
  - Fix the corroboration-fusion contract so domain-knowledge fusion lives inside
    fusion nodes, not in `join` — preserving lattice laws and preventing diamond
    double-counting.
  - Publish a stable `Observation` model + `ObservationSource` seam so reasoning
    never learns SRQL/NATS/CNPG.
  - Scaffold the full flat crate family with correct dependency tiers and clean
    Bazel targets; fill `causal-model`, `causal-ports`, and the L1
    confidence/state-feed seam in `causal-ingest`.
  - Enable the app-level state-change feed as an L1 source.
- Non-Goals:
  - No S1–S7 security causaloids (owned by `add-causal-security-detections`).
  - No identity↔asset↔flow bridge (owned by `add-identity-asset-flow-bridge`).
  - No mitigation policy table/actuation (owned by `add-causal-mitigation`).
  - No analyst TP/FP labeling surface (owned by `add-causal-detection-feedback`).
  - No re-derivation of the `add-causal-engine` chassis, emission plumbing, or
    reliability causaloids.

## Decisions

- **Decision: `SecVerdict::join` is the idempotent LUB, nothing more.**
  `join` takes `stage.max`, confidence LUB (`confidence.max` as an `Uncertain`
  LUB), `severity.max`, and evidence union with de-duplication; `Benign` is
  bottom. This keeps the DeepCausality lattice laws (commutativity, associativity,
  absorption/idempotence) so reconvergent graph folds are order-invariant and
  diamonds do not double-count.
  - Alternatives considered: putting noisy-OR/inverse-variance directly in `join`
    (rejected — breaks absorption/idempotence and double-counts diamond
    evidence); typed node-to-node graph transitions (rejected by the DC author —
    destroys reconvergent join).

- **Decision: corroboration fusion lives in the fusion node's `bind`/State
  channel.** The noisy-OR (`Aggregatable::Any`) / inverse-variance combination is
  the domain-knowledge part and runs inside a fusion node, not in `join`. Fusion
  is two-step: cluster correlated same-session evidence to one unit at
  representative (max) confidence, then combine across independent clusters, then
  reconstruct `Uncertain(mean, sigma)` for a bounded SPRT (`max_samples` ~200).
  - Alternatives considered: fusing all cross-domain evidence as conditionally
    independent (rejected — DNS+IOC+flow are the same session, correlated;
    combining them as independent inflates confidence).

- **Decision: L1 constructs confidence centrally.** The edge emits z-score/
  severity/episodes, not `Uncertain`, and only for metric-series; therefore
  `Observation.confidence` is constructed in L1 from the edge signal plus a
  calibration source. This is net-new engineering, not a pass-through.
  - Alternatives considered: pushing `Uncertain` construction to the edge
    (rejected — 6 of 8 domains have no edge producer; calibration must be central).

- **Decision: flat `rust/causal-*` crate family, Bazel model B.** Each crate is a
  flat `rust/<crate>` dir in the root `Cargo.toml` `members`, mirroring
  `rust/anomaly-*`. `causal-ports` holds the boundary traits as the isolation
  seam. One shared lockfile; `all_crate_deps` against `@rust_crates` just works.
  - Alternatives considered: a nested independent workspace under
    `rust/causal-engine/crates/*` (rejected — needs a second `Cargo.lock` +
    `crate.from_cargo` in `MODULE.bazel`, causing crate-universe skew).

## Risks / Trade-offs

- **`Uncertain` LUB semantics for confidence** → `confidence.max` as an
  `Uncertain` LUB must be defined so that the join stays idempotent and lawful;
  mis-defining it (e.g., as a mean) would break the lattice. Mitigation: spec the
  LUB explicitly and unit-test idempotence/associativity/absorption.
- **Process-global DC sample cache** (`global_cache.rs`, never-cleared memo) →
  reusing Uncertain IDs across ticks serves stale draws and grows unbounded.
  Mitigation: this milestone only defines the fusion contract; hot-path cache
  `clear()` semantics are deferred to the reasoning-loop milestone but flagged in
  Open Questions.
- **Scaffolding many empty crates** → risk of drift/dead crates. Mitigation:
  every crate must compile green under both `cargo` and Bazel from day one; empty
  crates carry a `//! ` module doc stating the milestone that fills them.
- **Enabling `STATE_CHANGE_EVENTS_ENABLED`** → turning on the feed adds NATS
  traffic. Mitigation: the publisher already exists and is gated; enabling it is a
  config flip plus a stream/consumer provision, coordinated with the chassis's
  Phase-0 state-feed task.

## Migration Plan

1. Add the ten flat `rust/causal-*` crates to root `Cargo.toml` `members` with
   `serviceradar-`-prefixed package names and per-crate `BUILD.bazel`
   (`rust_library`; bin adds `rust_binary`). Verify `cargo build` AND `bazel
   build` are both green (a green cargo build does not prove Bazel).
2. Implement `SecVerdict` + the lawful `Verdict` lattice in `causal-model` with
   lattice-law unit tests (idempotence, commutativity, associativity, absorption,
   bottom identity, top saturation).
3. Define the `Observation` model in `causal-model` and the boundary traits
   (`ObservationSource`, `ContextStore`, `Emitter`, `MitigationPolicy`,
   `ActionExecutor`) in `causal-ports`.
4. Add the central confidence-construction skeleton and the state-feed
   `ObservationSource` adapter in `causal-ingest`; enable
   `STATE_CHANGE_EVENTS_ENABLED` and provision the `signals.state.>` stream/
   consumer.
5. Rollback: the crate family is additive and behind no runtime path until later
   milestones compose the binary; reverting is removing the members and the
   feed-enable flag. No chassis code is modified destructively.

## Open Questions

- What exactly is the `Uncertain` LUB for the confidence field — `max` over
  `expected_value`, or a lattice join over the distribution — and does it keep
  `expected_value`/`standard_deviation` (fixed 1000-sample, no early-exit) off the
  hot path? (Resolve before the reasoning-loop milestone.)
- Which calibration source seeds the initial score→`Uncertain(mean, variance)`
  mapping before the analyst-label surface exists (owned by
  `add-causal-detection-feedback`)? A static prior is the Phase-0 placeholder.
- Per-tick DC sample-cache `clear()` semantics vs. entity/Uncertain-ID reuse —
  deferred to the reasoning-loop milestone but must be settled before SPRT runs on
  the hot path.
