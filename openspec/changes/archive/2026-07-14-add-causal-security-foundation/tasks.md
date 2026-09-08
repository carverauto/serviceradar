# Tasks: Scaffold the causal security engine (Phase 0 foundation)

Phase-0 foundation for the causal SECURITY engine. Extends the settled
`add-causal-engine` chassis; does NOT redefine it. Capabilities:
`causal-security-reasoning`, `causal-security-observations`.

**Implementation status (applied):** the Rust crate family is implemented and green under BOTH
build systems locally. **Cargo:** `build`/`test`/`clippy -D warnings`/`fmt --check` pass, 23 unit
tests. **Bazel (per-crate):** `bazel build //rust/causal-<crate>/...` builds all 14 targets and
`bazel test` passes all 4 test targets — the crate-universe auto-re-spliced from the updated
`Cargo.lock` (no manual repin needed for `deep_causality_algebra`/`deep_causality_uncertain`). Only
the whole-repo `//...` build is broken (unrelated), so per-crate targets are the local Bazel gate.
Runtime/infra items (enabling the state feed, the live NATS-backed adapter) are DEFERRED — they touch
the running system and are not locally verifiable.

## 1. Crate family scaffolding (capability: causal-security-reasoning)

- [x] 1.1 Create the flat `rust/causal-*` crate dirs as root-workspace members in
  root `Cargo.toml` `members` (mirroring `rust/anomaly-*`, no `crates/` subfolder,
  no nested `[workspace]`): `causal-model`, `causal-ports`, `causal-context`,
  `causal-ingest`, `causal-causaloids`, `causal-reasoning`, `causal-mitigation`,
  `causal-emit`, `causal-config`, and the `causal-engine` binary.
- [x] 1.2 Set `serviceradar-`-prefixed package names (dir `rust/causal-model` →
  package `serviceradar-causal-model`, matching `serviceradar-anomaly-core`).
- [x] 1.3 Wire the dependency tiers: `causal-model` → `causal-ports` →
  {`causal-context`, `causal-causaloids`, `causal-reasoning`, `causal-ingest`,
  `causal-mitigation`, `causal-emit`, `causal-config`} → `causal-engine` (bin);
  `causal-reasoning` and `causal-causaloids` do not depend on each other.
- [x] 1.4 Add DeepCausality deps (crates.io, in sync with the ctx tree): `causal-model`
  on `deep_causality_algebra = "0.2.0"`; `causal-reasoning` on
  `deep_causality_uncertain = "0.5.0"` (the only place an `Uncertain` is materialized);
  `causal-ingest` gates `srql`/`nats`/`cdc` features (no live backend yet).
  NOTE: `deep_causality` + `ultragraph 0.9` are deferred to `add-causal-security-detections`
  (the kill-chain graph milestone) — Phase 0 needs neither.
- [x] 1.5 Add a `BUILD.bazel` per crate (`rust_library` + `all_crate_deps(...)`;
  the bin adds `rust_binary`) so CI can build the crates; later-milestone crates carry
  a `//!` module doc naming the milestone that fills them.
- [x] 1.6 Verify `cargo build`/`cargo clippy -D warnings`/`cargo fmt --check`/
  `cargo test` are green for every new crate (Cargo gate), AND per-crate Bazel:
  `bazel build //rust/causal-<crate>/...` builds all 14 targets and `bazel test`
  passes all 4 test targets. (Only the whole-repo `//...` build is broken, for
  unrelated reasons — per-crate targets are the local Bazel gate.)
- [x] 1.7 The Bazel crate-universe auto-re-spliced from the updated `Cargo.lock`, so
  `all_crate_deps` resolves the new deps (`deep_causality_algebra`,
  `deep_causality_uncertain`, `deep_causality_num`/`_rand`, `uuid`) with no manual
  `scripts/update-rust-bazel-deps.sh` repin. Confirmed by the successful per-crate builds.

## 2. SecVerdict + lawful lattice (capability: causal-security-reasoning)

- [x] 2.1 Define `ConfidenceSummary { mean: f64 /* [0,1] */, variance: f64 }` in
  `causal-model` (deterministic; `Copy`), plus the `SecVerdict` enum, `Stage`
  (ATT&CK-tactic-ordered, `Ord`), `Severity`, `EvidenceRef` (with
  `signal_conf: ConfidenceSummary`, `cluster: EvidenceCluster`), and
  `type Confidence = ConfidenceSummary` — done in `confidence.rs`/`verdict.rs`.
- [x] 2.2 Implement `Verdict` for `SecVerdict`: `bottom` = `Benign`; `top` = the
  `Saturated` variant (a clean lattice top — cleaner than a synthetic saturated
  `Incident`); `join` = idempotent LUB (`stage.max`; confidence **max-on-mean** via
  `conf_lub`, tie → smaller `variance`; `severity.max`; canonicalized+de-duplicated
  evidence union). DeepCausality's live-`Uncertain` `Verdict::join` is deliberately NOT
  used for confidence (non-idempotent across independent leaves). `meet` = GLB;
  `complement` = MV-algebra `1 − mean` (an involution).
- [x] 2.3 `SecVerdict` satisfies `Default + Clone + Send + Sync + 'static + Debug`
  (auto for `Send + Sync + 'static`; derived otherwise).
- [x] 2.4 Unit-test the lattice laws (14 tests in `causal-model`): `join`/`conf_lub`
  idempotence, commutativity, associativity, absorption, `Benign` as join identity,
  `Saturated` absorption, the reconvergent two-`Incident`-same-entity escalation with
  evidence union (no double-count), and complement involution.

## 3. Corroboration fusion + hot-path discipline (capability: causal-security-reasoning)

- [x] 3.1 Author the closed-form fusion combiners (NOT in `Verdict::join`): `conf_lub`
  (per-cluster max-on-mean collapse) and `combine_independent` (cross-cluster noisy-OR
  on means + inverse-variance tightening) in `causal-model::confidence` — all operate on
  `ConfidenceSummary`, no sampling. NOTE: the evidence-`group_by_cluster` fusion NODE
  (grouping by `EvidenceCluster` at detection time) is deferred to
  `add-causal-security-detections`; the primitives it composes are done here.
- [x] 3.2 The CSM SPRT step (`causal-reasoning::sprt`): `sprt_fires` reconstructs
  `Uncertain::normal(mean, variance.sqrt())` and runs ONE bounded SPRT (`SprtParams`,
  `max_samples = 200`) via `greater_than(threshold).probability_exceeds(...)`.
  `expected_value`/`standard_deviation` are never called on the reasoning path.
- [x] 3.3 `clear_sample_cache_at_tick_barrier()` calls `with_global_cache(|c| c.clear())`;
  documented as the only DC lever, to run only at the tick barrier (no SPRT in flight).
- [x] 3.4 Unit-tests: identical evidence by two diamond paths counted once (`join`
  test); `combine_independent` raises mean + tightens variance; SPRT fires on a tight
  high-mean summary and not on a low-mean one; the tick-barrier clear is callable. NOTE:
  the explicit same-session-cluster-collapse-before-combine scenario ships with the
  `group_by_cluster` node in `add-causal-security-detections`.

## 4. Observation model + ports seam (capability: causal-security-observations)

- [x] 4.1 `Observation { entity, domain, confidence: ConfidenceSummary, features,
  ocsf_event_id: Uuid, observed_at }` + the `Domain`/`DomainFeatures` enums in
  `causal-model`.
- [x] 4.2 Boundary traits in `causal-ports`: `ObservationSource` (`stream` +
  `snapshot`), `ContextStore`, `Emitter`, `MitigationPolicy`, `ActionExecutor`.
- [x] 4.3 Reasoning isolation enforced structurally by the crate graph:
  `causal-reasoning` depends only on `causal-model` + `causal-ports` (+
  `deep_causality_uncertain`) and references no SRQL/NATS/CNPG type.

## 5. Central confidence construction (capability: causal-security-observations)

- [x] 5.1 `causal-ingest::build_observation` maps an edge robust z-score / near-binary
  hit into `Observation.confidence` through the `causal-config` calibration table
  (net-new central construction, not a pass-through).
- [x] 5.2 `causal-config::Calibration` — (a) continuous: logistic `σ(k·(z − z0))`,
  `k=0.5`,`z0=3.0`, anchored so z=4→~0.6 / z=8→~0.9 (parity with the deployed 4.0/8.0
  severity cutpoints); (b) near-binary: high-mean/low-variance on a hit, no observation
  on a miss; variance widened on low information (`!confirmed`, thin baseline, magnitude
  fallback). Config, re-fit by `add-causal-detection-feedback`.
- [x] 5.3 Unit-tests (`causal-config` + `causal-ingest`): logistic anchors at the
  4.0/8.0 cutpoints and is monotone; low information widens variance; an IOC hit →
  high-mean/low-variance; a continuous score to a near-binary domain → no observation.

## 6. Enable the state-change feed (capability: causal-security-observations)

- [ ] 6.1 **DEFERRED (runtime/infra — not locally verifiable):** enable
  `STATE_CHANGE_EVENTS_ENABLED` for the app-level `signals.state.<table>` publisher
  (`event_writer/state_change_publisher.ex`) and provision the `signals.state.>`
  JetStream stream/consumer. This is an ops/config change on the running system; do not
  flip it blindly.
- [~] 6.2 The `ObservationSource` seam is implemented with an in-memory source
  (`causal-ingest::InMemorySource`, unit-tested via `stream`/`snapshot`). **DEFERRED:**
  the live `signals.state.<table>` NATS-backed `ObservationSource` adapter (needs the
  NATS client + message schema; behind the `nats` feature) lands with 6.1.

## 7. Validation

- [x] 7.1 `openspec validate add-causal-security-foundation --strict` passes.
- [x] 7.2 No reintroduction of removed names (`signals.causal.*`, `CausalSignals`,
  pgoutput CDC) in the new crates; cross-references to sibling change-ids resolve.
