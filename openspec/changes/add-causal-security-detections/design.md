## Context

This is Milestone 2 of the causal SECURITY engine, derived from `openspec/notes/sr-causal-engine.md`
(§3 Context, §4.4 kill-chain graph, §4.5 CSM, §6 S1/S2/S4/S5/S6 catalog, §8 emission/automation loop,
§9 Phase 1). It EXTENDS the settled `add-causal-engine` chassis (fused single-pod `rust/causal-engine`,
three ingestion feeds, emission/automation loop, `god_view_nif` demotion, reliability causaloids C1–C13)
and DEPENDS ON `add-causal-security-foundation` (the `SecVerdict` lattice, `Observation`/`ObservationSource`
model, per-domain confidence construction, and crate scaffold). It does NOT re-decide chassis
infrastructure.

An intrusion is inherently cross-domain: an attacker touches DNS, flow, host/runtime, routing,
vulnerability state, and threat-intel in sequence. ServiceRadar already lands these domains in one plane
(CNPG + AGE `platform_graph` + NATS JetStream). This milestone turns that substrate into cross-domain
incident reasoning: a Security Context world model (Layer 2), a kill-chain `CausaloidGraph` and V1
causaloid catalog (Layer 3), and verdict emission that closes the automation loop.

## Goals / Non-Goals

- **Goals:**
  - A DeepCausality Security Context hypergraph mapping asset criticality/CVE/identity → `Datoid`,
    `platform_graph` reachability → `Spaceoid`, baselines → `Tempoid`, IOC → `Symboid`.
  - Bounded IOC hydration: IOC/CIDR matching stays in-DB; Context has a memory ceiling and a
    Datoid/Symboid refresh cadence separate from the topology freeze.
  - A frozen per-incident-hypothesis kill-chain `CausaloidGraph` with precursor-early evaluation.
  - The shippable V1 catalog S1/S2/S4/S5/S6 as cross-domain fusion nodes on today's schema.
  - A detect→respond CSM and a greenfield emitter that closes the automation loop into alerts +
    God-View.
- **Non-Goals:**
  - S3 (lateral) and S7 (credential attack): blocked on host-auth ingest; out of scope
    (coordinate `add-identity-asset-flow-bridge`).
  - Auto-mitigation actuation (block-flow/revoke-session/quarantine) and the shadow-first policy table:
    owned by `add-causal-mitigation`. V1 fires `alert_only`.
  - Forward-propagated next-stage prediction: Phase-2+ (needs calibrated stage-transition priors).
  - Counterfactual blast-radius / analyst-label calibration: later milestones.
  - Re-deciding the chassis (crate layout, feeds, `god_view_nif` demotion) — inherited from
    `add-causal-engine`.

## Decisions

- **Decision: Security Context is a DeepCausality hypergraph typed independently of the verdict `V`.**
  Structural heterogeneity lives in Context (`C`) and State (`S`); only `SecVerdict` is homogeneous.
  A causaloid reads Context internally (owns its ref via `new_with_context`).
  - Alternatives considered: pass world-model facts as observation fields (rejected — loses DC's
    freeze/unfreeze lifecycle and the reachability graph); a separate service (rejected — DC needs
    in-process Context on the hot path per the chassis decision).

- **Decision: Bounded IOC hydration — matching stays in-DB.** `threat_intel_*` / `otx_retrohunt_*` are
  NOT materialized wholesale as Symboids. The existing GIST containment index + `ip_threat_intel_cache`
  compute IOC/CIDR matches in-DB, surfaced as an L1 `Observation`. Symboids, if hydrated, are bounded by
  the active `expires_at` window under a Context memory ceiling, with a refresh cadence separate from the
  topology freeze.
  - Alternatives considered: Bloom/roaring bitsets (rejected — do not fit CIDR containment); full
    in-memory indicator set (rejected — unbounded Context growth, defeats the ceiling).

- **Decision: One `CausaloidGraph` per incident hypothesis.** Evaluate one graph per entity or correlated
  cluster so the propagating `V` is about a single incident. `freeze()` before reasoning;
  `evaluate_subgraph_from_cause` does topological forward propagation; reconvergent branches `join` via
  the idempotent LUB (`SecVerdict::join` = `stage.max`/`confidence.max`/`severity.max` + evidence union).
  Corroboration fusion (noisy-OR / inverse-variance) lives INSIDE a fusion node, NOT in `join` — this
  preserves the lattice laws and prevents diamond double-counting.
  - Alternatives considered: one global graph (rejected — `V` would conflate incidents and destroy
    reconvergent join semantics); typed node-to-node transitions (rejected by the DC author — destroys
    reconvergent join).

- **Decision: CSM threads entity/verdict via `CausalState` + a static registry, not a closure.**
  `CausalAction::new` takes a bare `fn() -> Result<(), ActionError>` pointer that cannot capture
  `entity_id`. A non-capturing `fn` reads the pending verdict for the current state from a registry keyed
  by entity id (set just before eval). `is_active()` (SPRT over the reconstructed `Uncertain<f64>`,
  `max_samples` ≈ 200) triggers `fire()`.
  - Alternatives considered: capturing closure (impossible — `fn`-pointer signature); boxed `dyn Fn`
    (rejected — not the DC API).

- **Decision: Emit on `signals.analytics.predictions.*` → `AnalyticsSignals` (verified current names).**
  The greenfield producer publishes verdicts via `ServiceRadar.Observability.CausalPredictionSubject`
  (`@subject_root "signals.analytics.predictions"`) with deterministic prediction IDs; `AnalyticsSignals`
  + `pipeline.ex` route them into `ocsf_events`, from which they re-enter
  `StatefulAlertEngine.evaluate_events/1` as `device.uid`-grouped alerts (OCSF `class_uid` 1008) and drive
  the God-View render. The legacy `signals.causal.*` / `CausalSignals` names do NOT exist and MUST NOT be
  used.
  - Alternatives considered: direct writes to `monitoring.alerts` (rejected — bypasses the alert engine
    and its durable rule state); new inbound plumbing (unnecessary — the normalization path already
    exists).

## Risks / Trade-offs

- **Collector provisioning:** every cross-domain leg assumes its collector is provisioned (flow, PowerDNS,
  falcosidekick, threat-intel, BMP/MTR, Bumblebee). → S1/S2/S4/S5/S6 "ship" against today's schema but a
  missing collector degrades a leg; fusion must tolerate an absent domain rather than fail closed.
- **Catalog-bounded coverage:** a technique manifesting only in an unmodeled domain is invisible until a
  causaloid is authored. → Budget ongoing per-technique authoring; V1 scope is exactly S1/S2/S4/S5/S6.
- **Correlated evidence double-counts confidence:** cross-domain does NOT imply independence
  (DNS-DGA + resolved-IP-IOC + flow-to-IP are the same session). → Two-step fusion: collapse each
  correlated cluster to one unit, then combine only across independent clusters.
- **DC process-global sample cache:** the sample cache is a process-global, never-cleared memo. → Define
  explicit per-tick `clear()` semantics / Uncertain-ID reuse in the reasoning loop so stale draws don't
  serve and memory doesn't grow unbounded; keep `expected_value`/`standard_deviation` off the hot path.
- **Context memory growth:** wholesale IOC hydration would blow the Context ceiling. → Mitigated by the
  in-DB-matching decision + `expires_at` bounding + separate refresh cadence.

## Migration Plan

1. Land `add-causal-security-foundation` first (dependency): `SecVerdict` lattice, `Observation` model,
   per-domain confidence.
2. Build `rust/causal-context` Security Context hydration + bounded-IOC policy against `platform_graph`
   and the in-DB IOC index; verify the Context memory ceiling.
3. Build the kill-chain `CausaloidGraph` in `rust/causal-reasoning` and the S1/S2/S4/S5/S6 causaloids in
   `rust/causal-causaloids`; unit-test precursor-early ordering and order-invariant `join`.
4. Wire the CSM (non-capturing action + registry) and the `rust/causal-emit` producer.
5. Author the `device.uid`-grouped `stateful_alert_rule` and confirm `AnalyticsSignals` routing;
   integration-test one prediction → alert end-to-end with no new inbound plumbing.
6. Map verdicts into the God-View buckets without a snapshot-contract change.
- **Rollback:** the producer is greenfield and idempotent; disabling emission stops predictions with no
  inbound-schema change. Detections are additive causaloids; removing them reverts to chassis-only
  behavior.

## Open Questions

- Per-incident graph granularity — one graph per entity vs. per correlated cluster — sets the
  hypotheses-per-tick multiplier for the perf budget (chassis Open-Question 2); resolve before load-test.
- Exact tick interval, max active hypotheses/tick, and p99 per-tick latency budget for V1 (chassis
  Open-Question 6).
- Which asset-criticality signal seeds the `Datoid` severity so `join` severity is meaningful (gap §7 #5)
  — coordinate with the foundation's tagging work.
