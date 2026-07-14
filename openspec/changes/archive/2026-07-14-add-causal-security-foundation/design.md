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

- **Decision: confidence is a deterministic `(mean, variance)` summary, not a live
  `Uncertain`; `join` is max-on-mean.** The verdict carries
  `ConfidenceSummary { mean: f64 /* [0,1] */, variance: f64 }`. `SecVerdict::join`
  selects the operand with the greater mean (tie → smaller variance) — an exact
  chain-lattice LUB (unconditionally idempotent/commutative/associative/absorptive),
  an `f64` compare, O(1), **no sampling and no graph growth on the hot path**. The
  full `Uncertain::normal(mean, variance.sqrt())` is reconstructed exactly once, at
  the CSM, for the single SPRT per incident hypothesis; reconstruction is one leaf
  node (`from_samples` already collapses to `Normal(mean,std)`, `uncertain_f64.rs:12-26`).
  `expected_value`/`standard_deviation` (fixed-N, no early-exit,
  `uncertain_statistics.rs:17-29,33-62`) therefore never run on the reasoning path.
  - Investigated: DeepCausality DOES ship `impl Verdict for Uncertain<f64>` with a
    lazy O(1) `join = max` node (`uncertain_verdict.rs:45-74`), but its idempotence
    holds ONLY when both operands are the same shared `Arc` leaf. At a real
    reconvergence the two confidences are independently computed leaves, so
    `join = max` becomes `E[max(A,B)] > A` — upward-biased, NOT idempotent (the same
    diamond-inflation we moved noisy-OR out of `join` to avoid), and it deepens the
    lazy graph so the SPRT walks a larger DAG each reconvergence.
  - Alternatives considered: a live `Uncertain<f64>` verdict + DC-native
    `Verdict::join` (rejected — fragile Arc-sharing idempotence that reconvergence
    violates → confidence inflation; graph-depth-growing SPRT cost; larger cache-leak
    surface; and inconsistent with §4.3, which reconstructs a fresh `normal` leaf).
  - Follow-up: align the note §4.2 (`uncertain_max(ca,cb)`) and the
    `causal-security-reasoning` "Security Verdict Lattice" requirement to this summary
    form.

- **Decision: Phase-0 calibration is a per-domain static config table reusing the
  deployed 4.0/8.0 z-score cutpoints.** The edge emits a robust median/MAD z-score in
  `[0,∞)` (`ReasonVerdict.score`), no probability/variance. L1 constructs
  `ConfidenceSummary` per domain via a config table with two families: (a) continuous
  domains (metric-series edge + DNS entropy, flow periodicity, auth/scan rates, BGP
  churn) map the z-score through a monotone logistic `mean = σ(k·(z − z0))` anchored so
  z=threshold(3.0)→~0.5, z=4→~0.6, z=8→~0.9 — matching the shipped anomaly severity
  bands (`anomaly-addon verdict.rs:461-473`; seasonal_disposition `severity_score`
  {20,55,75} `verdict_emitter.ex:235-252`); (b) near-binary domains (IOC exact/CIDR
  match, BGP new-origin/sub-prefix, auth first-seen) map a hit directly to
  high-mean/low-variance (a z-score is meaningless — the zero-dispersion fallback fires),
  a miss emits no Observation. Variance widens on low information (`!anomalous`/pending,
  `baseline_count < 30`, magnitude-fallback score).
  - Rationale: reusing the 4.0/8.0 cutpoints keeps the security engine in numeric
    parity with the deployed anomaly bands (AGENTS.md single-source rule), and the table
    is the exact seam the Phase-4 analyst-label loop (`add-causal-detection-feedback`)
    re-fits.
  - Alternatives considered: a fit-probability heuristic like `1 − rmse/scale` (rejected
    — the repo already deleted that overclaim; keep the mean provisional and the variance
    honestly wide until the label loop calibrates).

- **Decision: the DC sample cache is cleared whole at the per-tick barrier.** Because
  confidence flows as a summary and the only `Uncertain` materialization + sampling is
  the single SPRT per incident hypothesis at the CSM, the process-global cache
  (`global_cache.rs`: `OnceLock<RwLock<HashMap>>`, keyed `(uncertain_id, sample_index,
  sampler)`, unbounded, fresh monotonic IDs per construction) holds only the current
  tick's draws. The reasoning loop SHALL call `with_global_cache(|c| c.clear())` at the
  tick barrier (after all incident evaluations, no SPRT in flight), turning the memo into
  per-tick scratch, and SHALL bound SPRT `max_samples` (~200, not the 1000 default).
  - Investigated: the only reclamation lever is the whole-cache `clear()`
    (`global_cache.rs:87`); there is no per-node eviction, TTL, or capacity. IDs are never
    reused, so cross-tick memo gives no benefit — reconstruct fresh each tick + clear.
  - Alternatives considered: holding `Uncertain` handles stable across ticks to reuse the
    memo (rejected — new evidence each tick means we WANT fresh draws; stable handles serve
    stale draws). Upstream ask: a thread-local (DC already uses one under `cfg(test)`) or
    scoped/id-range cache would remove the manual clear — flagged for a DC contribution.

## Risks / Trade-offs

- **Confidence LUB correctness** → RESOLVED by carrying a `(mean, variance)` summary
  and defining `join` as max-on-mean (a chain lattice), instead of a live `Uncertain`
  whose DC-native `join = max` is only idempotent for shared `Arc` leaves and inflates
  at reconvergence. Mitigation: unit-test idempotence/associativity/absorption on the
  summary lattice.
- **Process-global DC sample cache** (`global_cache.rs`, unbounded, fresh IDs per
  construction) → RESOLVED by confining `Uncertain` materialization to the per-incident
  SPRT and clearing the whole cache at the per-tick barrier (see Decisions). Residual: a
  scoped/thread-local cache is a cleaner upstream fix.
- **Scaffolding many empty crates** → risk of drift/dead crates. Mitigation:
  every crate must compile green under `cargo` from day one (the local gate; Bazel
  is validated in CI only — see below); empty crates carry a `//! ` module doc
  stating the milestone that fills them.
- **Whole-repo Bazel build is broken** (unrelated) → but **per-crate** targets build
  and test fine locally: `bazel build //rust/causal-<crate>/...` + `bazel test` pass,
  and the crate-universe auto-re-splices from `Cargo.lock` (no manual repin for the new
  DC deps). Mitigation: use per-crate Bazel targets as the local Bazel gate alongside
  Cargo; do not gate on the broken `//...` build.
- **Enabling `STATE_CHANGE_EVENTS_ENABLED`** → turning on the feed adds NATS
  traffic. Mitigation: the publisher already exists and is gated; enabling it is a
  config flip plus a stream/consumer provision, coordinated with the chassis's
  Phase-0 state-feed task.

## Migration Plan

1. Add the ten flat `rust/causal-*` crates to root `Cargo.toml` `members` with
   `serviceradar-`-prefixed package names and per-crate `BUILD.bazel`
   (`rust_library`; bin adds `rust_binary`). Verify `cargo build`/`clippy`/`fmt`/
   `test` green LOCALLY, AND per-crate `bazel build //rust/causal-<crate>/...` +
   `bazel test` (both pass; the crate-universe auto-re-splices from `Cargo.lock`).
   Only the whole-repo `//...` build is broken (unrelated) — do not gate on it.
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

The three original Phase-0 open questions were investigated against the DeepCausality
and anomaly-core source and are now RESOLVED in Decisions above:

- ~~`Uncertain` LUB for confidence~~ → RESOLVED: `(mean, variance)` summary + max-on-mean
  chain lattice; the full `Uncertain` is materialized only at the CSM SPRT, so
  `expected_value`/`standard_deviation` never run on the reasoning path.
- ~~Calibration seed~~ → RESOLVED: a per-domain static config table reusing the deployed
  4.0/8.0 z-score cutpoints (logistic for continuous domains, direct high-mean for
  near-binary), re-fit later by `add-causal-detection-feedback`.
- ~~Per-tick sample-cache semantics~~ → RESOLVED: whole-cache `with_global_cache(|c| c.clear())`
  at the tick barrier; SPRT `max_samples` bounded (~200).

Residual (do not block Phase 0):

- Exact logistic parameters (`k`, `z0`) and per-domain base variance for the calibration
  table — set conservative defaults now; tune against real traffic + the label loop.
- SPRT `(threshold, confidence, epsilon)` operating point per stage — depends on the
  calibration and the perf budget (Q6 in the note); set in the reasoning-loop milestone.
- Upstream DC ask: a scoped/thread-local sample cache (DC already uses a thread-local
  under `cfg(test)`) to remove the manual per-tick clear when reasoning parallelizes.
