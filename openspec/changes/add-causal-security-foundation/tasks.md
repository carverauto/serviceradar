# Tasks: Scaffold the causal security engine (Phase 0 foundation)

Phase-0 foundation for the causal SECURITY engine. Extends the settled
`add-causal-engine` chassis; does NOT redefine it. Capabilities:
`causal-security-reasoning`, `causal-security-observations`.

## 1. Crate family scaffolding (capability: causal-security-reasoning)

- [ ] 1.1 Create the flat `rust/causal-*` crate dirs as root-workspace members in
  root `Cargo.toml` `members` (mirroring `rust/anomaly-*`, no `crates/` subfolder,
  no nested `[workspace]`): `causal-model`, `causal-ports`, `causal-context`,
  `causal-ingest`, `causal-causaloids`, `causal-reasoning`, `causal-mitigation`,
  `causal-emit`, `causal-config`, and the `causal-engine` binary.
- [ ] 1.2 Set `serviceradar-`-prefixed package names (dir `rust/causal-model` →
  package `serviceradar-causal-model`, matching `serviceradar-anomaly-core`).
- [ ] 1.3 Wire the dependency tiers: `causal-model` → `causal-ports` →
  {`causal-context`, `causal-causaloids`, `causal-reasoning`, `causal-ingest`,
  `causal-mitigation`, `causal-emit`, `causal-config`} → `causal-engine` (bin);
  `causal-reasoning` and `causal-causaloids` MUST NOT depend on each other.
- [ ] 1.4 Add DeepCausality deps where needed: `causal-model` on
  `deep_causality_uncertain` + `deep_causality_algebra`; `causal-context`/
  `causal-causaloids`/`causal-reasoning` on `deep_causality`; `causal-reasoning`
  on `ultragraph = "0.9"`; `causal-ingest` on `srql` + NATS (feature-gated).
- [ ] 1.5 Add a `BUILD.bazel` per crate (`rust_library` + `all_crate_deps(...)`;
  the bin adds `rust_binary`); mark later-milestone crates with a `//!` module doc
  naming the milestone that fills them.
- [ ] 1.6 Verify BOTH `cargo build`/`cargo clippy -D warnings`/`cargo fmt --check`
  AND `bazel build` are green for every new crate (a green cargo build does not
  prove the Bazel build).

## 2. SecVerdict + lawful lattice (capability: causal-security-reasoning)

- [ ] 2.1 Define the `SecVerdict` enum in `causal-model` (`Benign` bottom;
  `Incident { entity, stage, confidence: UncertainF64, severity, evidence:
  Vec<EvidenceRef> }`), plus `Stage` (ATT&CK-tactic-ordered, `Ord`), `Severity`,
  `EvidenceRef` (with `cluster: EvidenceCluster`), and `Confidence = UncertainF64`.
- [ ] 2.2 Implement `Verdict` for `SecVerdict`: `bottom` = `Benign`; `top` =
  saturated `Incident` (`Stage::Impact`, confidence ≈ 1, max severity); `join` =
  idempotent LUB (`stage.max`, confidence LUB via `uncertain_max`, `severity.max`,
  de-duplicated evidence union); `meet` = GLB (`stage.min`/`confidence.min`/
  `severity.min`); `complement` over the confidence field.
- [ ] 2.3 Derive/implement `Default + Clone + Send + Sync + 'static + Debug` on
  `SecVerdict` to satisfy the graph-reasoning `V: Verdict` bound.
- [ ] 2.4 Unit-test the lattice laws: `join` idempotence, commutativity,
  associativity, absorption, `Benign` as join identity, and the reconvergent
  two-`Incident`-same-entity escalation with evidence union (no double-count).

## 3. Corroboration fusion contract (capability: causal-security-reasoning)

- [ ] 3.1 Author the fusion helpers in a fusion-node module (NOT in
  `Verdict::join`): `group_by_cluster` → per-cluster `uncertain_max` collapse;
  cross-cluster `inverse_variance_mean`/`inverse_variance_sigma`; reconstruct
  `Uncertain::normal(mean, sigma)`.
- [ ] 3.2 Wire an `UncertainParameter` (threshold, confidence, epsilon, bounded
  `max_samples` ~200) so SPRT can test the reconstructed `Uncertain`.
- [ ] 3.3 Unit-test: identical evidence arriving by two diamond paths is counted
  once (join), and same-session DNS+IOC+flow collapse to one cluster before
  combining with the independent host-runtime cluster.

## 4. Observation model + ports seam (capability: causal-security-observations)

- [ ] 4.1 Define `Observation { entity: EntityKey (canonical sr: id), domain:
  Domain, confidence: UncertainF64, features: DomainFeatures, ocsf_event_id: Uuid,
  observed_at: Timestamp }` and the `Domain`/`DomainFeatures` enums in
  `causal-model`.
- [ ] 4.2 Define the boundary traits in `causal-ports`: `ObservationSource`
  (`stream` + `snapshot`), `ContextStore`, `Emitter`, `MitigationPolicy`,
  `ActionExecutor` — the isolation seam.
- [ ] 4.3 Assert (via a compile-level test/doc) that the reasoning crates depend
  only on `causal-model`/`causal-ports` and reference no SRQL/NATS/CNPG type.

## 5. Central confidence construction (capability: causal-security-observations)

- [ ] 5.1 In `causal-ingest`, add the score→`Uncertain(mean, variance)`
  construction skeleton that maps an edge z-score/OCSF severity plus a calibration
  source into `Observation.confidence` (net-new; not a pass-through).
- [ ] 5.2 Seed a static-prior calibration placeholder (the analyst-label
  calibration is owned by `add-causal-detection-feedback`); unit-test a
  metric-series z-score mapping to an `Uncertain(mean, variance)`.

## 6. Enable the state-change feed (capability: causal-security-observations)

- [ ] 6.1 Enable `STATE_CHANGE_EVENTS_ENABLED` for the app-level
  `signals.state.<table>` publisher (`event_writer/state_change_publisher.ex`) and
  provision the `signals.state.>` JetStream stream/consumer.
- [ ] 6.2 In `causal-ingest`, add the `signals.state.<table>` `ObservationSource`
  adapter that surfaces each transition as an `Observation` keyed to the entity's
  canonical `sr:`-prefixed id (NOT pgoutput CDC); unit-test an `ocsf_devices`
  transition mapping to an `Observation`.

## 7. Validation

- [ ] 7.1 Run `openspec validate add-causal-security-foundation --strict` and fix
  any errors until it passes.
- [ ] 7.2 Confirm no reintroduction of removed names (`signals.causal.*`,
  `CausalSignals`, pgoutput CDC) and that all cross-references to sibling
  change-ids resolve.
