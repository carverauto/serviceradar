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

- [ ] 2.1 Define `ConfidenceSummary { mean: f64 /* [0,1] */, variance: f64 }` in
  `causal-model` (deterministic; `Copy`), plus the `SecVerdict` enum (`Benign`
  bottom; `Incident { entity, stage, confidence: ConfidenceSummary, severity,
  evidence: Vec<EvidenceRef> }`), `Stage` (ATT&CK-tactic-ordered, `Ord`),
  `Severity`, `EvidenceRef` (with `signal_conf: ConfidenceSummary`, `cluster:
  EvidenceCluster`), and `type Confidence = ConfidenceSummary`.
- [ ] 2.2 Implement `Verdict` for `SecVerdict`: `bottom` = `Benign`; `top` =
  saturated `Incident` (`Stage::Impact`, `mean` ≈ 1, max severity); `join` =
  idempotent LUB (`stage.max`; confidence **max-on-mean** — the greater-`mean`
  operand wins, tie → smaller `variance`; `severity.max`; de-duplicated evidence
  union). Do NOT use DeepCausality's live-`Uncertain` `Verdict::join` for
  confidence (non-idempotent across independent leaves). `meet` = GLB
  (`stage.min`/lower-mean/`severity.min`); `complement` over the mean.
- [ ] 2.3 Derive/implement `Default + Clone + Send + Sync + 'static + Debug` on
  `SecVerdict` to satisfy the graph-reasoning `V: Verdict` bound.
- [ ] 2.4 Unit-test the lattice laws on the `ConfidenceSummary` max-on-mean lattice:
  `join` idempotence, commutativity, associativity, absorption, `Benign` as join
  identity, the reconvergent two-`Incident`-same-entity escalation with evidence
  union (no double-count), and that `join` performs no sampling.

## 3. Corroboration fusion + hot-path discipline (capability: causal-security-reasoning)

- [ ] 3.1 Author the fusion helpers in a fusion-node module (NOT in
  `Verdict::join`), operating **closed-form on `ConfidenceSummary`** (no sampling):
  `group_by_cluster` → per-cluster max-on-mean collapse; cross-cluster
  `inverse_variance_mean`/`inverse_variance_sigma` (and/or noisy-OR on means) over
  the summaries.
- [ ] 3.2 At the CSM only, reconstruct `Uncertain::normal(mean, variance.sqrt())`
  from the fused summary and wire an `UncertainParameter` with a bounded
  `max_samples` (~200) for the single SPRT. Keep `expected_value`/
  `standard_deviation` off the reasoning path entirely.
- [ ] 3.3 Implement the per-tick DC sample-cache clear: call
  `with_global_cache(|c| c.clear())` at the tick barrier (after all incident
  evaluations, no SPRT in flight); document that the whole-cache clear is the only
  DC lever and must not run mid-flight.
- [ ] 3.4 Unit-test: identical evidence arriving by two diamond paths is counted
  once (join); same-session DNS+IOC+flow collapse to one cluster before combining
  with the independent host-runtime cluster; and fusion draws zero samples until
  the single CSM SPRT.

## 4. Observation model + ports seam (capability: causal-security-observations)

- [ ] 4.1 Define `Observation { entity: EntityKey (canonical sr: id), domain:
  Domain, confidence: ConfidenceSummary, features: DomainFeatures, ocsf_event_id:
  Uuid, observed_at: Timestamp }` and the `Domain`/`DomainFeatures` enums in
  `causal-model`.
- [ ] 4.2 Define the boundary traits in `causal-ports`: `ObservationSource`
  (`stream` + `snapshot`), `ContextStore`, `Emitter`, `MitigationPolicy`,
  `ActionExecutor` — the isolation seam.
- [ ] 4.3 Assert (via a compile-level test/doc) that the reasoning crates depend
  only on `causal-model`/`causal-ports` and reference no SRQL/NATS/CNPG type.

## 5. Central confidence construction (capability: causal-security-observations)

- [ ] 5.1 In `causal-ingest`, add the score→`ConfidenceSummary` construction that
  maps an edge robust z-score (`ReasonVerdict.score`) / OCSF severity into
  `Observation.confidence` (net-new; not a pass-through). Route it through a
  `causal-config` calibration table.
- [ ] 5.2 Define the per-domain static calibration table: (a) continuous family —
  logistic `σ(k·(z − z0))` anchored to reuse the deployed 4.0/8.0 z-score cutpoints
  (numeric parity with `anomaly-addon severity_id_from_score`); (b) near-binary
  family — direct high-mean/low-variance on a hit (IOC/CIDR match, BGP
  new-origin/sub-prefix, auth first-seen), no `Observation` on a miss; variance
  widened on low information (`!anomalous`/pending, thin baseline, magnitude
  fallback). Keep it config (`add-causal-detection-feedback` re-fits it).
- [ ] 5.3 Unit-test: a metric-series z-score maps to a `ConfidenceSummary` at the
  4.0/8.0 anchors, and an IOC match maps to high-mean/low-variance while a miss
  yields no `Observation`.

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
