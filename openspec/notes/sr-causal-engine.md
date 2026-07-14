# ServiceRadar — Next-Gen Causal Security Engine (Design Note)

> **Purpose.** The design for a cross-domain causal reasoning engine whose *end* is
> **early intrusion detection, incident reasoning, and mitigation** — repositioning
> ServiceRadar toward NDR/XDR with a defensible moat: native cross-domain data fusion ×
> explainable causal reasoning on one data plane.
>
> **Status.** Verified against the repo (2026-07). Feasible/practical/useful, spec-ready after the
> corrections folded in here. Prior-round inaccuracies (compile-blocking sketches, stale subject/
> processor names, "available"-vs-"net-new" overclaims) are corrected inline and marked ⚠️.

## Relationship to `openspec/changes/add-causal-engine` (READ FIRST)

There is an **active, settled OpenSpec change, `openspec/changes/add-causal-engine`** (proposal.md,
design.md, tasks.md, specs, runbooks). It defines the **engine chassis**: the fused single-pod
`rust/causal-engine`, the three ingestion feeds, the emission/automation-loop, entity-ID reuse, the
`god_view_nif` demotion, and a **reliability** causaloid catalog (C1–C13). **This note does not
replace it — it extends the same chassis with the security framing** (the cross-domain security
causaloid catalog S1–S7, the `SecVerdict` design, the mitigation-authority policy table). Inherit its
infrastructure decisions; do not re-decide them.

Two reconciliations were applied here after verifying against current code:
- **The prediction subject/processor is `signals.analytics.predictions.>` → `AnalyticsSignals`**
  (`event_writer/processors/analytics_signals.ex`; subject built by
  `ServiceRadar.Observability.CausalPredictionSubject`, `@subject_root "signals.analytics.predictions"`).
  `causal_signals.ex` / `signals.causal.*` **do not exist** (legacy, removed). ⚠️ **The
  `add-causal-engine` proposal.md still uses the stale `signals.causal.*` / `CausalSignals` names** —
  those should be corrected in that change too; this note uses the real ones.
- **State feed is the app-level `signals.state.<table>` publisher, NOT pgoutput CDC.** `add-causal-engine`
  DECISION-1 explicitly rejected logical replication; the publisher exists as
  `event_writer/state_change_publisher.ex` (`StateChangePublisher`), gated off by
  `STATE_CHANGE_EVENTS_ENABLED`.

> **DeepCausality (DC).** Authored by Marvin Hansen; source at `ctx/deep_causality`. API cited by
> `file:line` in the appendix. `god_view_nif` today is a 244-line reactive blast-radius stub; it is
> demoted to a renderer per `add-causal-engine`, with real reasoning in `rust/causal-engine`.

---

## 0. The big idea

An intrusion is **inherently cross-domain**: an attacker touches DNS, network flow, host/runtime,
identity, routing, vulnerability state, and threat-intel — in sequence. Every mainstream tool
(NDR, SIEM, EDR, TIP, vuln scanner) watches **one** domain and therefore either drowns in false
positives or misses novel attacks. The **conjunction across weakly-correlated domains** is
simultaneously higher-precision and **earlier** (the early kill-chain stages are cross-domain).

ServiceRadar lands these domains in **one plane (CNPG)** before any reasoning happens — the data moat
XDR vendors fail to reach through post-hoc integration. ⚠️ **Honest scope:** that plane is *partly*
OCSF-normalized, not uniformly (see §2 tiers). **DeepCausality is the reasoning moat:** mechanistic,
directional, explainable inference — a *story* (auditable causal chain), not an ML *score*.

**Defensible claims (narrowed after review):**
- **Novel instances of a modeled technique** fire without a signature or training sample (the genuine
  edge over signatures/ML). **Novel combinations of known primitives** are caught, and single-domain
  signature-evasion is defeated by cross-domain conjunction.
- ⚠️ **Not** "detects any novel attack." Coverage is bounded by the **hand-authored causaloid catalog**
  (§6): a technique manifesting only in an unmodeled domain is invisible until a causaloid is authored.
  The spec must budget ongoing per-technique authoring.
- **Early:** precursor stages (recon/scan/DNS-staging) are observable before impact — *this is real in
  V1*. ⚠️ **"Predicts the next move"** is deferred: it needs calibrated stage-transition priors (gap
  §7), so it is a Phase-2+ property, not V1.

**To what end does the engine exist?** The one thing impossible per-domain or at the edge:
**cross-domain incident reasoning.** The edge answers *"is this series weird?"*; the engine answers
*"is this an attack, what stage, and what do we do?"*

---

## 1. Architecture: three independent layers

Three layers with hard boundaries so each evolves independently — a first-class requirement.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ LAYER 3 — CAUSAL REASONING   (pure; no DB/NATS knowledge)                 │
│   Causaloids · CausaloidGraph (kill chain) · CSM (detect→respond)         │
│   Counterfactual (blast radius/triage) · Correction (online loop)         │
│   Consumes: Observations + Context.   Emits: SecVerdict.                  │
└───────────────▲───────────────────────────────▲──────────────────────────┘
                │ ObservationSource trait        │ ContextStore trait
┌───────────────┴──────────────┐  ┌──────────────┴───────────────────────────┐
│ LAYER 1 — DATA INTEGRATION   │  │ LAYER 2 — CONTEXT (world model)          │
│  EmbeddedSrql (CNPG/AGE)     │  │  DC Context hypergraph:                  │
│  JetStream subscriber        │─▶│  assets/criticality, IOCs, topology,     │
│  signals.state.<table> feed  │  │  identities, baselines                   │
│  + CENTRAL per-domain        │  │  (Contextoid: Datoid/Spaceoid/Tempoid/   │
│    detectors → Uncertain     │  │   Symboid)                               │
│  Output: Observation model   │  │                                          │
└──────────────────────────────┘  └──────────────────────────────────────────┘
        ▲ CNPG · NATS JetStream · AGE graph (platform_graph)  (ServiceRadar data plane)
```

`add-causal-engine` names the same layering as modules inside one crate
(`context_hydrator`/`domain_model`/`reasoner`/`emitter`/`snapshot`, `ContextStore` between hydrator
and reasoner). §8.1 refines those modules into separate crates for stronger isolation. The
`ContextStore` trait is the future in-process↔networked seam.

---

## 2. Layer 1 — Data Integration

**Responsibility:** turn the ServiceRadar data plane into a stable `Observation` model plus per-domain
`Uncertain` confidences. Only this layer knows CNPG, SRQL, NATS.

**Three feeds** (aligned to `add-causal-engine`):
- **`EmbeddedSrql` over CNPG** (`rust/srql`, `execute_query`/`graph_cypher`) — cold-start state,
  on-demand Timescale rollups, AGE topology snapshots (target graph **`platform_graph`**).
- **JetStream subscriber** — live deltas on `signals.analytics.>` (predictions/inventory),
  `arancini.updates.>`, `siem.events.>`, `bmp.events.>`, and the OCSF-normalized event stream.
  ⚠️ *Not* `signals.causal.*` (removed legacy).
- **`signals.state.<table>` app-level transition feed** — `ocsf_devices` / `service_status` /
  `health_events` (+ virtualization + AGE-projection) transitions via `StateChangePublisher`.
  ⚠️ *Not* pgoutput CDC (rejected by `add-causal-engine` DECISION-1; no logical replication exists).
  It is implemented but **gated off** (`STATE_CHANGE_EVENTS_ENABLED`) — enabling it is a build item.

### Security-domain substrate — three tiers (⚠️ not uniformly "already OCSF-normalized")

| Domain | Substrate tier | CNPG source | Notes |
|---|---|---|---|
| Flow | base table, OCSF | `ocsf_network_activity` (src/dst AS, sampling_rate) | the one truly OCSF-normalized standing table |
| Routing | base tables, **native (non-OCSF)** | `bmp_routing_events`, `bgp_routing_info`, `mtr_hops` | native schema, not OCSF |
| Vulnerability | base tables, **native** | `trivy_findings`, `vulnerability_*`, `endpoint_vulnerability_matches`, endpoint SBOM | KEV/exploit ranking already ships (see §6 S4) |
| Threat intel | base tables, **native** | `threat_intel_*`, `otx_retrohunt_*`, `ip_*_cache` | IOC/CIDR data; GIST containment index |
| DNS | **addon-gated** OCSF promotion | `ocsf_events` class 4003 (via PowerDNS addon → `pdns.ocsf`); SRQL entity `dns_activity` | present only if PowerDNS collector deployed |
| Host/runtime | **addon-gated** OCSF promotion | `ocsf_events` (via Falco → `falco_events.ex`); `logs`, OTEL | present only if falcosidekick deployed |
| Recon/scan | **SRQL views** over `ocsf_events` | `scan_activity` (class 6007), `security_findings` (cat 2) — Bumblebee addon producer | real producer exists (ships today) |
| Identity/auth | ⚠️ **console-only — substrate GAP** | `user_auth_events`, `security_events`, `auth_lockouts` | covers ServiceRadar web console (`ng_users`) ONLY — **no fleet/host SSH/RDP/Windows auth**. See [`sr-host-auth-gap.md`](./sr-host-auth-gap.md) |

⚠️ **Global deployment caveat:** every cross-domain leg assumes its collector/integration is
provisioned (flow-collector, PowerDNS, falcosidekick, threat-intel feeds). "Ships today" in §6 means
*builds on today's schema with no new tables*, subject to that provisioning.

### Edge/central split — corrected

⚠️ The edge does **not** emit `Uncertain`. `rust/anomaly-core` emits `ReasonVerdict{anomalous: bool,
score: f64}` + an OCSF `severity_id` (1–5) + episode lifecycle, and it covers **only host/device
metric-series** (cpu/mem/disk/SNMP counters/interface rates/ICMP RTT). Therefore:
- **L1 must CONSTRUCT** each `Observation.confidence: ConfidenceSummary` (a deterministic
  `(mean, variance)`, §4.2) centrally from the edge robust z-score (`ReasonVerdict.score`, `[0,∞)`) via a
  **per-domain static calibration table** (§7): a monotone logistic anchored to reuse the deployed
  **4.0/8.0** z-score severity cutpoints for continuous domains (numeric parity with the shipped anomaly
  bands), and a direct high-mean/low-variance mapping for near-binary domains (IOC/CIDR match, BGP
  new-origin, auth first-seen). Net-new engineering, not a pass-through; the table is config the
  disposition-feedback change re-fits.
- **6 of 8 Observation domains** that drive S1–S7 (DNS, Flow, Auth, Routing, ThreatIntel, Scan, plus
  Falco-Host) have **no edge producer today** — their per-domain confidence is derived **centrally**
  in L1 from raw OCSF/native rows (new central detectors), or scored directly by the causaloids. The
  "edge = anomaly for all domains, center = fusion" framing is **target-state**, not current.

```rust
/// Stable model the reasoning layer sees. No SRQL/NATS types leak past this.
pub struct Observation {
    pub entity: EntityKey,          // canonical sr:-prefixed id (RuntimeGraph.canonical_runtime_id/1)
    pub domain: Domain,             // Dns | Flow | Auth | Host | Routing | Vuln | ThreatIntel | Scan
    pub confidence: ConfidenceSummary, // DERIVED in L1 (per-domain calibration of edge score); §4.2
    pub features: DomainFeatures,   // domain-specific payload (enum)
    pub ocsf_event_id: Uuid,        // provenance back to CNPG
    pub observed_at: Timestamp,
}

pub trait ObservationSource {
    fn stream(&self) -> impl Iterator<Item = Observation>;      // JetStream / signals.state deltas
    fn snapshot(&self, entity: &EntityKey) -> Vec<Observation>; // SRQL on-demand
}
```

---

## 3. Layer 2 — Context (the DC world model)

**Responsibility:** build/maintain the DeepCausality **Context hypergraph** — the world model an
observation is judged against. Hydrated from L1; own lifecycle (`freeze`/`unfreeze` on topology change).

| Contextoid | Security payload | Source |
|---|---|---|
| **`Datoid`** | asset criticality, CVE exposure, identity privilege | `ocsf_devices`, `vulnerability_*`, auth tables |
| **`Spaceoid`** | network segment / topology position / reachability | AGE graph (`platform_graph`) |
| **`Tempoid`** | time-of-day baselines, dwell windows, beacon periodicity | Timescale rollups |
| **`Symboid`** | IOC / threat-intel indicators | `threat_intel_*`, `otx_retrohunt_*` |

A causaloid reads context internally (owns its ref via `new_with_context`).

⚠️ **Memory strategy (spec must fix):** do **not** hydrate `threat_intel_*`/`otx_retrohunt_*`
wholesale as Symboids. Prefer keeping IOC/CIDR matching **in-DB** (existing GIST containment index +
`ip_threat_intel_cache`) as an L1 Observation; if Symboids are needed in Context, bound them by the
existing `expires_at`/active window. (Bloom/roaring do not fit CIDR containment — do not prescribe
them.) Give fast-changing Datoid/Symboid state (CVE, IOC feeds) a refresh cadence **separate** from the
topology freeze, and set a Context memory ceiling.

```rust
pub trait ContextStore {
    fn context(&self) -> &BaseContext;
    fn hydrate(&mut self, src: &dyn ObservationSource);
    fn on_topology_change(&mut self);   // unfreeze/refreeze the AGE-derived graph
}
```

**Channel orthogonality:** DC's channels type Context (`C`) and State (`S`) **independently** of the
propagating verdict `V` (§5). All structural heterogeneity lives in Context/State; only `V` is
homogeneous.

---

## 4. Layer 3 — Causal Reasoning

Pure reasoning over Observations + Context, emitting `SecVerdict`.

### 4.1 The four DC reasoning modes → four security jobs

| DC mode (example) | Security job | Primitive |
|---|---|---|
| **`Uncertain` + inverse-variance fusion** (`sensor_processing`) | Cross-domain **evidence fusion** under noise | `Uncertain`, SPRT `UncertainParameter`. ⚠️ the inverse-variance fuse is a **hand-rolled pattern**, not a library fn (§4.3) |
| **`CausaloidGraph` + `evaluate_subgraph_from_cause`** | **Kill-chain inference** (forward, precursor-early) | homogeneous `V: Verdict`, `Verdict::join` (LUB) at reconvergence |
| **Counterfactual `alternate_value`** (`cascade_failure`) | **Blast-radius simulation** + **alert triage** | `CausalFlow` / `PropagatingProcess` interventions |
| **Correction `branch_with`+`alternate_value` loop** (`ddos_detector`) | The **online detect→mitigate control loop** | `iterate_n`, `SlidingWindow` in State |
| **`CSM` (`CausalState`+`CausalAction`)** | detect→**respond** trigger | `is_active()` → `fire()` |

### 4.2 Verdict types — a lawful lattice `join`; corroboration lives elsewhere

⚠️ **Corrected design.** DC's `Verdict` trait is a **lawful bounded lattice**: it requires
`bottom/top/meet/join/complement`, with `join(self, other)` the idempotent LUB (bool `||`, f64 `max`).
Its laws (commutativity, associativity, **absorption/idempotence**) are what make graph reconvergence
order-invariant AND avoid **diamond double-counting** (the same upstream evidence reaching a node by
two paths). Therefore:

- **Confidence flows as a deterministic `ConfidenceSummary { mean, variance }`, NOT a live `Uncertain`.**
  DC *does* ship `impl Verdict for Uncertain<f64>` with a lazy O(1) `join = max` node
  (`uncertain_verdict.rs:45-74`), but its idempotence holds **only when both operands are the same
  shared `Arc` leaf**; at a real reconvergence the two confidences are independently-computed leaves, so
  `join = max` becomes `E[max(A,B)] > A` — **upward-biased, not idempotent** (and it deepens the lazy
  graph the single SPRT must walk). So the verdict carries the summary instead.
- **`SecVerdict::join` = the idempotent LUB** (`stage.max`; confidence **max-on-mean** — greater-`mean`
  operand wins, tie → smaller `variance`; `severity.max`; evidence union). It is a lawful chain-lattice
  op and a pure `f64` compare — **no sampling on the hot path**.
- **The corroboration fusion (noisy-OR / inverse-variance) is NOT `join`.** It runs **inside a fusion
  node** (the intra-node `bind`/State channel — where DC puts `Aggregatable::Any = 1−∏(1−pᵢ)`), and is
  **closed-form on the `(mean, variance)` summaries**. The single `Uncertain::normal(mean, sigma)` is
  materialized **once, at the CSM**, for the SPRT (§4.3). This fusion is the part that "cannot be
  abstract, needs domain knowledge" (§5). Keeping it out of `join` preserves the lattice laws and
  prevents double-counting corroborated evidence on diamonds.
- ⚠️ *Correction to an earlier claim:* order-invariance is **not** the reason to keep noisy-OR out of
  `join` (noisy-OR is commutative+associative). The reasons are the **absorption/idempotence** lattice
  laws and diamond double-counting.

```rust
/// Deterministic confidence carried by the verdict (mean in [0,1]). NOT a live Uncertain:
/// the full Uncertain::normal(mean, variance.sqrt()) is rebuilt only at the CSM for the SPRT.
#[derive(Clone, Copy, Debug, Default)]
pub struct ConfidenceSummary { pub mean: f64, pub variance: f64 }
pub type Confidence = ConfidenceSummary;

/// ATT&CK-tactic-ordered kill-chain progression (Ord => join uses stage.max).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum Stage {
    #[default] Recon = 1, InitialAccess, Execution, Persistence, PrivEsc,
    CredAccess, Discovery, Lateral, Collection, C2, Exfil, Impact,
}

pub struct EvidenceRef {
    pub domain: Domain, pub ocsf_event_id: Uuid,
    pub attck: Option<AttckTechnique>,   // T1071, T1021, T1567, ...
    pub signal_conf: Confidence, pub observed_at: Timestamp,
    pub cluster: EvidenceCluster,        // session | host_runtime | recon | auth — used for §4.3 fusion
}

// SecVerdict must satisfy the graph-reasoning bound: Default + Clone + Send + Sync + 'static + Debug.
#[derive(Clone, Debug, Default)]
pub enum SecVerdict {
    #[default] Benign,                    // BOTTOM: join identity
    Incident {
        entity: EntityKey, stage: Stage, confidence: Confidence,
        severity: Severity, evidence: Vec<EvidenceRef>,
    },
}

impl Verdict for SecVerdict {
    fn bottom() -> Self { SecVerdict::Benign }
    fn top() -> Self { /* saturated Incident: Stage::Impact, confidence≈1, max severity */ }

    /// Idempotent LUB at graph reconvergence (same incident hypothesis => same entity).
    fn join(self, other: Self) -> Self {
        use SecVerdict::*;
        match (self, other) {
            (Benign, x) | (x, Benign) => x,
            (Incident { entity: e, stage: sa, confidence: ca, severity: va, evidence: mut xa },
             Incident { stage: sb, confidence: cb, severity: vb, evidence: xb, .. }) => {
                xa.extend(xb);
                Incident {
                    entity: e,
                    stage: sa.max(sb),                    // LUB, idempotent
                    confidence: conf_lub(ca, cb),         // max-on-mean (tie→smaller variance); no sampling
                    severity: va.max(vb),                 // NOT noisy-OR (that is §4.3, in the fusion node)
                    evidence: dedup(xa),
                }
            }
        }
    }
    fn meet(self, other: Self) -> Self { /* GLB: stage.min, lower-mean, severity.min */ }
    fn complement(self) -> Self { /* lattice complement over the mean */ }
}
// conf_lub: pick the operand with the greater mean (tie → smaller variance). A chain lattice on the
// mean → unconditionally idempotent/commutative/associative/absorptive; a pure f64 compare.
fn conf_lub(a: ConfidenceSummary, b: ConfidenceSummary) -> ConfidenceSummary {
    if (a.mean, -a.variance) >= (b.mean, -b.variance) { a } else { b }
}
```

### 4.3 Uncertainty & fusion (inside a node; the domain-knowledge part)

⚠️ **Corrected.** Fusion is **closed-form on the deterministic `ConfidenceSummary { mean, variance }`**
(no sampling); the single `Uncertain` is reconstructed **only at the CSM** for the SPRT. The
`inverse_variance`/`noisy-OR` combiners are **new ServiceRadar code**, not DC primitives (zero repo
hits) — DC's `sensor_processing` inverse-variance is a hand-rolled inline pattern that already collapses
`Uncertain` → `(mean, std)`, so carrying the summary directly is the same idea without the round-trip.

The independence assumption (open-question, now **committed as a V1 mitigation**): cross-domain does
**not** imply conditional independence. DNS-DGA + resolved-IP-IOC + flow-to-that-IP are the **same
session** (correlated); Host/Falco and recon-history are genuinely independent. So fuse in two steps:

```rust
// Each Observation carries a deterministic ConfidenceSummary (constructed in L1, §2). No sampling here.

// STEP 1 — collapse each correlated cluster to ONE unit at its representative (max-mean) confidence.
//   clusters: session (DNS+IOC+flow-to-IP) | host_runtime (Falco) | recon | auth
let per_cluster: Vec<ConfidenceSummary> = group_by_cluster(&evidence)
    .map(|c| c.iter().map(|e| e.signal_conf).reduce(conf_lub).unwrap());

// STEP 2 — combine INDEPENDENT clusters (noisy-OR on means / inverse-variance), still closed-form.
let fused: ConfidenceSummary = combine_independent(&per_cluster);   // (mean, variance), no sampling

// AT THE CSM ONLY — materialize ONE Uncertain and run the single bounded SPRT.
let u = Uncertain::normal(fused.mean, fused.variance.sqrt());
let param = UncertainParameter::new(/*threshold*/0.9, /*confidence*/0.95, /*epsilon*/0.05, /*max*/200);
let fired = u.probability_exceeds(0.9, 0.95, 0.05, 200)?;   // sequential, early-exit
```

⚠️ SPRT `max_samples` = **200** is ample for a small-arity fusion node (the 1000 default is
over-provisioned; `probability_exceeds` is sequential with early-exit at a Wald boundary). Because the
only `Uncertain` materialization is this per-incident SPRT, the reasoning loop clears the DC global
sample cache whole at the **tick barrier** (§10 Q6). DC's inverse-variance pattern is validated for
redundant estimators of *one* quantity, so the cluster step is what keeps its cross-domain reuse honest.

### 4.4 Kill-chain `CausaloidGraph`

Each stage is a causaloid (itself a §4.3 fusion node, or a `from_causal_graph` subgraph); edges are the
kill chain; `evaluate_subgraph_from_cause` does topological forward propagation over the frozen
hypergraph, reconvergent joins via §4.2 (LUB). **Evaluate one graph per incident hypothesis** (one
entity or correlated cluster) so `V` is about one incident. Reuse canonical `sr:`-prefixed IDs
(`RuntimeGraph.canonical_runtime_id/1`); do not invent a parallel ID space. Reasoning uses
`ultragraph 0.9` graph algorithms (Gap G is already upstream per `add-causal-engine`).

```rust
let mut kc = CausaloidGraph::new(0);
let recon   = kc.add_root_causaloid(scan_recon)?;
let access  = kc.add_causaloid(initial_access)?;
let exec    = kc.add_causaloid(execution)?;
let c2      = kc.add_causaloid(c2_beacon)?;
let lateral = kc.add_causaloid(lateral_move)?;
kc.add_edge(recon, access)?; kc.add_edge(access, exec)?;
kc.add_edge(exec, c2)?; kc.add_edge(exec, lateral)?;
kc.freeze();                                              // required before reasoning
let verdict = kc.evaluate_subgraph_from_cause(access, &initial_access_effect);
```

Precursor nodes (recon/scan) fire before impact — early detection in V1. Forward-propagated *prediction
of the next stage* is Phase-2+ (needs calibrated stage priors, §7).

### 4.5 CSM — detect→respond

⚠️ **Corrected.** `CausalAction::new` takes a **bare `fn` pointer** (`fn() -> Result<(), ActionError>`),
which cannot capture `entity_id`. Thread the entity/verdict through `CausalState` and read it from a
**static registry/queue** in a non-capturing `fn`:

```rust
// non-capturing fn — pulls the pending verdict for this state from a registry keyed by entity id.
fn mitigate() -> Result<(), ActionError> {
    let verdict = PENDING.take_for_current_state()?;   // set just before eval
    dispatch_mitigation(verdict)                        // -> northbound action (see §4.7a / §7 gap)
}
let state  = CausalState::new(entity_id, 1, evidence, incident_causaloid, Some(param));
let action = CausalAction::new(mitigate, "isolate + alert", 1);
let csm = CSM::new(&[(&state, &action)]);
csm.eval_single_state(entity_id, &fresh_evidence)?;   // is_active (SPRT) → fire()
```

⚠️ `dispatch_mitigation` targets the `northbound_action_*` framework, which today is a **generic,
provider-neutral dispatch/audit shell with NO block-flow/revoke-session/quarantine actions** — those
are aspirational (see §7 gap and §4.7a). Only device/interface-target actions (e.g. NAC port-shut) are
expressible, and only via a registered provider that does not yet exist.

### 4.6 Counterfactual — blast-radius simulation + triage

- **Attack-path / blast radius.** Topology in Context, an accumulating compromised-set in State,
  composed `.alternate_value()` interventions drive the cascade (`cascade_failure` template).
  `do(compromise = X)` run forward = blast radius **before** the attacker moves. **V1 scope is
  network-tier reachability only** (AGE `platform_graph`); true service-dependency / identity blast
  radius is blocked on §7 gap #1 and co-scheduled for Phase 2. This is a Phase-2 deliverable.
- **Alert triage / explainability (ITE).** Re-run fusion with one cluster knocked out, diff the verdict
  (`y1 − y0`). Collapse without the IOC cluster ⇒ it is *load-bearing* ⇒ say so in the alert; holds ⇒
  over-determined ⇒ higher confidence. The causal explanation a SOC reads.

> Scope: `alternate_value` is counterfactual value substitution, **not** Pearl `do()`-surgery; for
> blast-radius the compose-interventions-over-carried-State pattern is correct and sufficient.

### 4.7a Mitigation authority — a config table, shadow-first

Which verdicts auto-fire vs. require a human is **not** hardcoded — a runtime **policy table** in CNPG
(`platform` schema, Elixir migration + Ash resource, modeled on `stateful_alert_rules`). Author rules
in **shadow mode**, watch what they *would* do, then flip to enforce. The CSM fires "the action"; the
action is a **policy dispatch** returning `{auto_fire, require_approval, alert_only, suppress}`.
**Default-deny.**

⚠️ The response **actions** this table dispatches (block-flow, revoke-session, isolate/quarantine) **do
not exist yet** (§4.5). The policy table is designed and buildable; the underlying northbound action
descriptors + provider are a **Phase-3 build item** (§7). So this closes the *authority* decision, not
the *actuation*.

```
CSM.is_active (SPRT) ──▶ CausalAction.fire ──▶ policy.decide(verdict, blast_radius)
                                                   │
     ┌─────────────────────┬────────────────────┬─┴──────────────┐
   auto_fire          require_approval        alert_only        suppress
 northbound_action*   enqueue + notify        raise alert      drop (tuning)
   (*Phase-3)          approver role            only
        └──────────────── all outcomes append to mitigation_decisions (audit) ─────┘
```

**Policy table** `platform.causal_mitigation_policies` (first enabled rule by `priority`; predicate
columns AND-ed; `NULL` = wildcard):

```sql
CREATE TABLE platform.causal_mitigation_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL, description text,
  priority integer NOT NULL, enabled boolean NOT NULL DEFAULT true,
  mode text NOT NULL DEFAULT 'shadow' CHECK (mode IN ('shadow','enforce')),
  -- match predicate (verdict dimensions; NULL = any) ---
  min_stage text, max_stage text, min_confidence numeric, min_severity text,
  blast_radius_max integer,                         -- SAFETY: auto-fire only if predicted blast ≤ N
  asset_criticality text[], attck_in text[], domain_in text[], entity_tag_match jsonb,
  -- decision ---
  authority text NOT NULL CHECK (authority IN ('auto_fire','require_approval','alert_only','suppress')),
  action_type text,                                 -- Phase-3 descriptors; NULL for alert_only
  action_params jsonb DEFAULT '{}',
  -- guardrails ---
  approver_role text, max_fires_per_window integer, window_seconds integer,
  cooldown_seconds integer, expires_at timestamptz,
  created_by text, created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now()
);
```

**Decision audit** `platform.mitigation_decisions` (append-only, hypertable candidate): `verdict_ref,
entity, stage, confidence, blast_radius, matched_policy_id, authority, action_type, mode, outcome
('fired'|'enqueued'|'alerted'|'suppressed'|'would_fire'|'failed'), approver, decided_at`. In shadow an
`auto_fire` rule writes `outcome='would_fire'` and does nothing else — review, then flip to `enforce`.
`blast_radius_max` gates on the §4.6 counterfactual computed *before* the policy is consulted.

### 4.7 Correction — the online loop + anti-poisoning

The `ddos_detector` is literally a security detector and carries the key adversarial lesson:

```rust
CausalFlow::from(initial).iterate_n(N, |tick| {
    tick.bind(analyze_tick)                          // ingest one sample; update SlidingWindow z-score
        .branch_with(
            |v, s, _| s.consecutive_anomalies >= trigger_slots && !s.mitigated,
            |hot|  hot.update_state(record).alternate_value(MITIGATE),  // latch once
            |cold| cold)
}).into_process();
```

1. **Baseline-withholding (anti-poisoning):** `if !anomalous { window.push(sample) }` — anomalous
   samples never enter the baseline, defeating the **"boil-the-frog" slow-ramp** attack.
2. **Consecutive-slots debounce** — no response on a single noisy spike.
3. **Latch-once + operator-gated release:** abatement confirmed on **raw** offered load before stand-down.

---

## 5. The `V == V` question — settled

**Where imposed:** only on the two graph-*reasoning* traits, via `Causaloid<V, V, PS, C>`
(`graph_reasoning/mod.rs:34`; impls `causable_graph.rs:15,25`). Not on `Causaloid` (a single node can
be `I ≠ O`) nor the container (`CausableGraph<Causaloid<I,O,PS,C>>`, `causable_graph.rs:35`). Only
whole-graph propagation needs `V, V`.

**Why correct:** what flows on edges is the **verdict**; reconvergent branches must **`join`**, which
needs a common type. Heterogeneity lives in the other three channels — Context (`C`), State (`S`), and
the intra-node `bind` chain. Two tools deliberately: the Flow monad `bind` for heterogeneous typed
pipelines *inside* a node; the `CausaloidGraph` for homogeneous-`V` reconvergent join *across* the
chain.

**DC-author ruling (confirmed):** typed node-to-node graph transitions are a non-starter (they destroy
reconvergent join). The node join is the point. ⚠️ **Refined by review:** `Verdict::join` itself IS a
**lawful, abstract lattice op** (the LUB). The part that "cannot be abstract, needs domain knowledge"
is the **corroboration fusion** (§4.3), which lives in the aggregatable/`bind`/State channel — **not**
in `join`. `join = max` keeps the lattice laws (`graph_fold_order_invariant`, plus absorption/
idempotence to avoid diamond double-counting). DC ships a Lean relay-termination proof
(`MAX_RELAY_ROUNDS = 1024`) — bounded adaptive `RelayTo` cycles over the topological pass, so
"hypergraph with bounded relay," not "DAG."

**Conclusion:** no DC rework. One `SecVerdict` enum with a lawful lattice `join`; domain-knowledge
fusion inside nodes; evaluate per incident hypothesis. The confidence field specifically is a
deterministic `ConfidenceSummary` with a max-on-mean LUB — DC's live `Uncertain::join`
(`uncertain_verdict.rs:45-74`) is idempotent only for shared `Arc` leaves, so it is **not** used on
graph edges (§4.2); the single `Uncertain` is materialized only at the CSM SPRT.

---

## 6. Security causaloid catalog (mapped to ATT&CK)

Cross-domain fusion nodes (§4.3) feeding the kill-chain graph (§4.4). This is the **security** catalog;
`add-causal-engine`'s C1–C13 is the **reliability** catalog on the same chassis. "Ships today" =
builds on today's schema (subject to §2 collector provisioning).

| ID | Causaloid | Domains fused | Stage / ATT&CK | Ships today? |
|---|---|---|---|---|
| S1 | C2 beaconing | DNS(DGA) ∧ flow(periodicity) ∧ threat-intel ∧ host(Falco) | C2 / T1071, T1568 | ✅ |
| S2 | Data exfiltration | flow(large egress) ∧ S1 prior | Exfil / T1041, T1567 | ✅ |
| S3 | Lateral movement | auth(host) ∧ flow(new internal SMB/RDP) ∧ topology(segment cross) ∧ vuln | Lateral / T1021 | ⚠️ needs **host-auth** ([`sr-host-auth-gap.md`](./sr-host-auth-gap.md)) + identity↔asset bridge (§7) |
| S4 | Exposed CVE under live exploitation | vuln(**existing KEV** ranking) ∧ scan(exposure) ∧ host(runtime) | Exec / T1190 | ✅ — *new value is the scan∧host fusion; KEV prioritization already ships in `endpoint_vulnerability_matches`* |
| S5 | Route diversion / MITM | BGP(anomaly) ∧ flow(unexpected AS) ∧ MTR(path change) | C2/Collection / T1557 | ✅ (sources: BMP analytics + MTR consensus) |
| S6 | Recon/scanning precursor | scan_activity ∧ topology exposure | Recon / T1595 | ✅ (OCSF views via Bumblebee addon) |
| S7 | Credential attack | auth(**host**) ∧ flow ∧ time(off-hours) | CredAccess / T1110 | ⚠️ needs **host-auth** — console-auth only today ([`sr-host-auth-gap.md`](./sr-host-auth-gap.md)) |

⚠️ Corrections from review: S4 retitled (KEV ranking already ships — the increment is the fusion, not
the ranking); **S7 demoted from ✅ to ⚠️** (its auth leg has no fleet/host data today). S1/S2/S5/S6
ship; S3/S7 blocked on host-auth.

---

## 7. Data/context gaps (security-specific), ranked

1. **Identity ↔ asset ↔ flow bridge** — highest leverage. No graph of *which identity can reach which
   asset* / *which assets are crown jewels*. Unblocks full S3. Aligns with `add-causal-engine` Phase 2
   (Gap A: OTEL service edges + attributed_flow). New: `service_endpoints(entity, ip, port, proto)` +
   identity-privilege edges in AGE.
2. **Host-auth ingest** — the Identity/auth substrate is console-only. Detailed in
   [`sr-host-auth-gap.md`](./sr-host-auth-gap.md); blocks S3 and S7. **Deferred** (separate track).
3. **Per-domain confidence construction** — the edge emits z-scores/severity, not `Uncertain`, and
   covers only metric-series. L1 needs central detectors for DNS/Flow/Auth/Routing/ThreatIntel/Scan
   and a **calibration** from score→`Uncertain(mean, variance)`. Net-new.
4. **Mitigation action descriptors + provider** — `northbound_action_*` has no block-flow/
   revoke-session/quarantine actions; author descriptors + a registered provider (Phase-3).
5. **Asset criticality / exposure tagging** — a `Datoid` attribute so `join` severity is real.
6. **ATT&CK technique tagging on causaloids** — populates `EvidenceRef.attck`, SOC-legible.
7. **Disposition feedback loop** — ⚠️ `rust/anomaly-disposition` holds **statistical dispositions on
   metric buckets, not analyst labels** — it is the **wrong source**. A TP/FP labeling surface exists
   **nowhere** in the codebase. Net-new build: an analyst-verdict store on alerts/findings **plus** a
   calibration mapping from labels to the per-domain `Uncertain` variances. (Metrics-only crate cannot
   calibrate DNS/flow/auth anyway.)

---

## 8. Placement & output path (extends `add-causal-engine`)

- **Standalone `rust/causal-engine`**, single fused pod for V1 (DC needs in-process Context on the hot
  path). L1/L2/L3 are traits so the split is cheap later.
- **SRQL:** depend on `rust/srql` as an **internal library** (`EmbeddedSrql`); semi-stable is
  acceptable. Keep the dependency confined to the `ingest` crate (§8.1).
- **Output + automation loop:** a greenfield producer publishes
  **`signals.analytics.predictions.{device_uid|incident_id}`** (subject via
  `ServiceRadar.Observability.CausalPredictionSubject`) with deterministic IDs. The existing
  **`AnalyticsSignals`** processor (`event_writer/processors/analytics_signals.ex`) +
  `pipeline.ex:484` route `signals.analytics.predictions.*` into `ocsf_events`; from there predictions
  (a) **re-enter `StatefulAlertEngine.evaluate_events/1`** as `device.uid`-grouped alerts (OCSF
  `class_uid 1008`) — *closing the automation loop, not merely rendering* — and (b) drive the God-View
  4-bucket render. **No new inbound plumbing; only the producer half.**
- **Entity-ID alignment:** reuse `RuntimeGraph.canonical_runtime_id/1` (`sr:` prefix); handle
  endpoint-cluster summary nodes so verdicts on a clustered device id still render.
- **Demote `god_view_nif`** causality to a renderer stub per `add-causal-engine` (extract
  `src/core/causality.rs`, drop DC deps, rejoin workspace). Incremental + reversible.

### 8.1 Crate structure (Bazel model **B** — flat `rust/causal-*` crates, existing convention)

⚠️ **Resolved:** follow the existing ServiceRadar convention exactly — each crate is a **flat
`rust/<crate>` directory listed in the root `Cargo.toml` `members`**, mirroring the existing
**`anomaly-*` family** (`rust/anomaly-core`, `rust/anomaly-addon`, `rust/anomaly-disposition`). **No
`crates/`/`bin/` subfolder and no nested `[workspace]`.** The default `all_crate_deps` against
`@rust_crates` then works, there is **one shared lockfile** (no crate-universe skew), and the
`rust/srql` path dependency is a clean intra-workspace edge. (The rejected alternative — a nested
independent workspace — would need a second `Cargo.lock` + `crate.from_cargo` in `MODULE.bazel` à la
`rdp-connector-probe`.) These crates **refine** `add-causal-engine`'s single-crate modules
(`context_hydrator`/`domain_model`/`reasoner`/`emitter`/`snapshot`) into separate crates.

Directories (each a root-workspace member, exactly like `rust/anomaly-*`): `rust/causal-model`,
`rust/causal-ports`, `rust/causal-context`, `rust/causal-ingest`, `rust/causal-causaloids`,
`rust/causal-reasoning`, `rust/causal-mitigation`, `rust/causal-emit`, `rust/causal-config`, and the
binary `rust/causal-engine`. Package names take the `serviceradar-` prefix (dir `rust/causal-model` →
package `serviceradar-causal-model`, matching `serviceradar-anomaly-core`).

| Category | Crate (`rust/<dir>`) | Isolates | Depends on |
|---|---|---|---|
| **data** | `causal-model` | vocabulary + `SecVerdict` + lawful lattice `Verdict` impl (§4.2) | `deep_causality_uncertain`, `deep_causality_algebra` |
| *(seam)* | `causal-ports` | `ObservationSource`, `ContextStore`, `Emitter`, `MitigationPolicy`, `ActionExecutor` | `causal-model` |
| **context** | `causal-context` | L2 DC hypergraph | `causal-model`, `causal-ports`, `deep_causality` |
| **injection** | `causal-ingest` | L1 SRQL/JetStream/state-feed adapters — **only** crate touching `rust/srql`/NATS/CNPG; backends feature-gated | `causal-model`, `causal-ports`, `srql` |
| **coding** | `causal-causaloids` | detection code S1–S7 + kill-chain topology | `causal-model`, `causal-ports`, `causal-context`, `deep_causality` |
| **reasoning** | `causal-reasoning` | generic engine (graph eval, CSM, correction, counterfactual); generic over `V: Verdict`; uses `ultragraph 0.9` | `causal-model`, `causal-ports`, `causal-context`, `deep_causality` |
| **dedicated** | `causal-mitigation` | policy engine (§4.7a) | `causal-model`, `causal-ports` |
| **dedicated** | `causal-emit` | `SecVerdict` → `signals.analytics.predictions.*` | `causal-model`, `causal-ports`, NATS |
| **dedicated** | `causal-config` | env/threshold config | `causal-model` |
| *(root)* | `causal-engine` **(bin)** | composition root / DI + tick loop | all of the above |

**Dependency tiers:** `causal-model` → `causal-ports` → {`causal-context`, `causal-causaloids`,
`causal-reasoning`, `causal-ingest`, `causal-mitigation`, `causal-emit`, `causal-config`} →
`causal-engine` (bin). `causal-reasoning` and `causal-causaloids` are siblings that never depend on
each other (the bin composes them).

**Isolation guarantees:** new collector/table/subject → `ingest` only; new world-model → `context`
only; new detection → `causaloids` only; new fusion/join → `model` only; new authority tier →
`mitigation` config only; in-process→networked → re-impl `ports`.

**Notes:** each crate gets its own `BUILD.bazel` (`rust_library` + `all_crate_deps(...)`; bin adds
`rust_binary`) so **CI** can build it. ⚠️ **Local verification is Cargo-only for now** — the Bazel
config is broken on non-x86 machines and is not worth fixing locally, so `cargo build` / `cargo clippy`
/ `cargo fmt` / `cargo test` are the local gate and the **`BUILD.bazel` files are validated in CI (x86)**,
not locally. Edition: match the repo default (2021) unless a workspace-wide bump is chosen. Follow DC
conventions (one type per module, no `unsafe` via workspace lint, static dispatch, no prelude).

---

## 9. Roadmap (aligned to `add-causal-engine` phases)

| Phase | Scope | Deliverable |
|---|---|---|
| **0 — Pre-V1 (days)** | Scaffold `rust/causal-engine/crates/*` as root-workspace members; `model` + `ports`; `SecVerdict` + lawful lattice `join`; enable `STATE_CHANGE_EVENTS_ENABLED`; **build the per-domain confidence-construction** (gap §7 #3) for the domains S1/S2/S4/S5/S6 need | Skeleton compiles; lattice + fusion unit-tested |
| **1 — V1 (weeks)** | L1 (EmbeddedSrql + `signals.analytics.>`/`*_CAUSAL` + `signals.state.>`), L2 Context, kill-chain graph, CSM, causaloids **S1/S2/S4/S5/S6**; emit `signals.analytics.predictions.*` → `AnalyticsSignals` → `ocsf_events` → `StatefulAlertEngine` alerts | Cross-domain detections become alerts (loop closed) + God-View render |
| **2 — Cross-domain inflection (months)** | Gap #1 identity↔asset↔flow (with `add-causal-engine` Gap A / attributed_flow); ship **S3**; counterfactual blast-radius (network-tier) | Service/identity-level reasoning + attack-path |
| **3 — Online + response (months)** | Correction loop (§4.7); mitigation **action descriptors + provider** (gap #4); `causal_mitigation_policies` shadow-first → enforce | Closed-loop detect→mitigate |
| **4 — Feedback (ongoing)** | Build the analyst TP/FP labeling surface + variance calibration (gap #7); ATT&CK tagging; **host-auth ingest** unblocks S3/S7 | Self-tuning precision/recall |

---

## 10. Open questions (status)

1. ~~SRQL coupling~~ **RESOLVED:** internal library, confined to `ingest`. (§8/§8.1)
2. **Per-incident graph granularity:** one graph per entity vs. per correlated cluster? Sets the
   hypotheses-per-tick multiplier for the **perf budget** below — resolve first.
3. ~~Auto-mitigation authority~~ **RESOLVED:** config table (§4.7a), shadow-first — *but* the actuation
   (northbound actions) is a Phase-3 build item (§7 #4).
4. ~~noisy-OR independence~~ **RESOLVED (V1 mitigation committed):** cluster correlated same-session
   evidence before fusion; combine only across independent clusters (§4.3). `join` is LUB, not noisy-OR.
5. ~~Tenancy~~ **RESOLVED:** one engine per deployment, one deployment per tenant; single Context per schema.
6. **Perf budget (partially RESOLVED):** the DC sample-cache leak and hot-path sampling are resolved —
   confidence flows as a `ConfidenceSummary` (§4.2) so only the per-incident CSM SPRT ever samples, and
   the reasoning loop clears the whole DC global cache (`with_global_cache(|c| c.clear())`,
   `global_cache.rs:87`) at the **tick barrier** (ids are fresh-per-construction with no per-node evict,
   so a whole-cache clear is the only lever and is correct here). SPRT `max_samples` ~200;
   `expected_value`/`standard_deviation` (fixed-N, no early-exit) never run on the reasoning path.
   *Still to set:* tick interval, max active incident hypotheses/tick (from Q2), and a **p99** per-tick
   latency budget. *Upstream ask:* a scoped/thread-local DC cache (DC already uses a thread-local under
   `cfg(test)`) would drop the manual clear when reasoning parallelizes across incidents.

---

## Appendix — key references (by `file:line`)

DC source root: `ctx/deep_causality`.

**Reasoning core** — `Causaloid<I,O,STATE,CTX>` `types/causal_types/causaloid/mod.rs:62` (ctors :119,
:150, :201, :298); `CausalFn`/`ContextualCausalFn` `alias/alias_function.rs:24,40`; `MonadicCausable::
evaluate` `causaloid/causable.rs:84`.
**Graph reasoning (`V,V` bound)** — `MonadicCausableGraphReasoning` `graph_reasoning/mod.rs:34`;
`evaluate_subgraph_from_cause` :117; impls `causaloid_graph/causable_graph.rs:15,25`; heterogeneous
container `:35`; `MAX_RELAY_ROUNDS=1024` `mod.rs:24`.
**Verdict lattice** — `deep_causality_algebra` `Verdict` trait requires `bottom/top/meet/join/complement`
(`algebra/verdict.rs:20-31`); `join` is the LUB (bool `||`, f64 `max`); `Aggregatable`/`Any` (noisy-OR)
is where corroboration lives (`utils/monadic_collection_utils.rs`). ⚠️ `impl Verdict for Uncertain<f64>`
(`uncertain_verdict.rs:45-74`) is a lazy O(1) `join = max` node but idempotent **only** for a shared
`Arc` leaf (per-sample memo by `Arc::as_ptr`); independently-built leaves give `E[max]>A` → not
idempotent. Hence the verdict confidence is a deterministic `(mean,variance)` summary, not a live
`Uncertain` (§4.2). `Uncertain::normal(mean,std)` reconstruction is one leaf (`from_samples` already
collapses to `Normal`, `uncertain_f64.rs:12-26`).
**CSM** — `CausalAction::new(action: fn()->Result<(),ActionError>, ...)` **fn-pointer, no captures**
`csm_types/csm_action/mod.rs:47,55`; `CausalState::new` `csm_state/mod.rs:60`; `CSM::new` `csm/mod.rs:65`;
`CsmEvaluable` (impls for `bool`/`UncertainBool`/`UncertainF64`) `extensions/evaluable/mod.rs`.
**Context** — `Contextoid`/`ContextoidType{Datoid/Spaceoid/Tempoid/Symboid/...}` `contextoid/*`.
**Uncertainty** — `Uncertain::{normal,bernoulli,point}`; `greater_than`→`UncertainBool`;
`probability_exceeds`/`to_bool` = **sequential SPRT with early-exit** (batches of 10, Wald boundaries,
`sprt_eval.rs:22-94`; `implicit_conditional` default `0.95/0.05/1000`); `expected_value`/
`standard_deviation` (**fixed-N, no early-exit**, `uncertain_statistics.rs:17-29,33-62`);
`UncertainParameter::new(threshold,confidence,epsilon,max_samples)`. Sample cache is process-global +
unbounded (`OnceLock<RwLock<HashMap>>`, key `(uncertain_id, sample_index, sampler)`), ids fresh per
construction (`NEXT_UNCERTAIN_ID`), only lever = whole-cache `clear()` (`global_cache.rs:87`) via
`with_global_cache` → clear at the tick barrier (§10 Q6).

**Edge anomaly / calibration** — `rust/anomaly-core` emits `ReasonVerdict{score: f64 robust median/MAD
z-score [0,∞), anomalous, breached, baseline_count, ...}` (`types.rs:86-101`), metric-series only; no
probability/variance. Deployed score→severity cutpoints **4.0/8.0** → severity {2,3,4}
(`anomaly-addon verdict.rs:461-473`; seasonal_disposition `severity_score {20,55,75}`,
`verdict_emitter.ex:235-252`) — the calibration anchors L1 reuses (§2/§7). No score→probability mapping
exists (`anomaly-disposition` `confidence` is an interval-coverage level, not a fit-probability).
**Counterfactual/correction** — `AlternatableValue::alternate_value`; `CausalFlow::{alternate_value,
branch_with,iterate_n,update_state}`; templates: `sensor_processing/model.rs:170-215` (inline
inverse-variance, **not** a primitive), `cascade_failure/model.rs:113-154`,
`corrective_ddos_detector/main.rs:61-83` + `model.rs:78-134` (baseline-withholding).

**ServiceRadar (verified current names)**
- Prediction subject/processor: `signals.analytics.predictions.>` → `AnalyticsSignals`
  (`event_writer/processors/analytics_signals.ex`; `event_writer/config.ex:355`;
  `observability/causal_prediction_subject.ex:9`; `event_writer/pipeline.ex:484`). ⚠️ `causal_signals.ex`
  / `signals.causal.*` do **not** exist (legacy).
- State feed: `StateChangePublisher` (`event_writer/state_change_publisher.ex`), gated
  `STATE_CHANGE_EVENTS_ENABLED`; subjects `signals.state.<table>`.
- Automation loop: `StatefulAlertEngine.evaluate_events/1`; canonical IDs
  `RuntimeGraph.canonical_runtime_id/1`.
- AGE graph is **`platform_graph`** (migration `20260204090000`), superseding `serviceradar`.
- KEV ranking already ships: `endpoint_vulnerability_matches`.
- `god_view_nif/src/core/causality.rs` (244-line stub) → `rust/causal-engine` (per `add-causal-engine`).

**OpenSpec** — reconcile with `openspec/changes/add-causal-engine` (proposal/design/tasks/specs). ⚠️ its
proposal.md uses the stale `signals.causal.*`/`CausalSignals` names; correct there too.
