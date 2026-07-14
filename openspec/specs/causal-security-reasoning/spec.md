# causal-security-reasoning Specification

## Purpose
TBD - created by archiving change add-causal-security-foundation. Update Purpose after archive.
## Requirements
### Requirement: Security Verdict Lattice

`SecVerdict` SHALL implement DeepCausality's lawful `Verdict` lattice, providing
`bottom`, `top`, `meet`, `join`, and `complement`. `join(self, other)` SHALL be
the idempotent least-upper-bound (LUB): it SHALL take `stage.max`, combine
confidence by **max-on-mean over the deterministic `ConfidenceSummary { mean,
variance }`** (the operand with the greater `mean` wins; ties SHALL break toward
the smaller `variance`), take `severity.max`, and union the evidence sets. The
confidence combine SHALL NOT be a live-`Uncertain` `max` node: DeepCausality's
`impl Verdict for Uncertain<f64>` is idempotent only when both operands are the
same shared `Arc` leaf and produces an upward-biased `E[max(A,B)] > A` at a real
reconvergence, so it MUST NOT be used as the verdict confidence. `Benign` SHALL be
the lattice bottom (the `join` identity). `SecVerdict` MUST additionally satisfy
`Default + Clone + Send + Sync + 'static + Debug` so it satisfies the
graph-reasoning `V: Verdict` bound. The `join` operation SHALL obey the lattice
laws (commutativity, associativity, and absorption/idempotence) so that
reconvergent graph propagation is order-invariant and diamond paths do not
double-count evidence.

#### Scenario: Reconvergent join of two Incident verdicts escalates without double-counting

- **WHEN** two `Incident` verdicts about the SAME entity reach a reconvergent
  node — one at an earlier stage/lower severity and one at a later stage/higher
  severity, with overlapping and distinct evidence
- **THEN** `join` SHALL produce a single `Incident` for that entity whose stage
  is the `max` of the two, whose severity is the `max` of the two, and whose
  confidence is the `ConfidenceSummary` of the greater-mean operand (tie → smaller
  variance)
- **AND** the merged evidence SHALL be the de-duplicated union so that evidence
  shared by both inputs appears exactly once
- **AND** `join` SHALL perform no sampling (it is an `f64`/field comparison)

#### Scenario: Benign is the join identity (bottom)

- **WHEN** `join` is applied to any verdict `x` together with `Benign`
- **THEN** the result SHALL equal `x` regardless of argument order
- **AND** `Benign` SHALL be reported as the lattice `bottom`

#### Scenario: Join is idempotent and order-invariant

- **WHEN** the same `Incident` verdict is joined with itself, or a set of
  verdicts is folded by `join` in any order
- **THEN** joining a verdict with itself SHALL return an equivalent verdict
  (idempotence) with evidence unioned once, not duplicated
- **AND** the folded result SHALL be identical regardless of fold order
  (commutativity/associativity)

### Requirement: Corroboration Fusion Is Not Join

Noisy-OR and inverse-variance corroboration fusion MUST NOT be implemented inside
`Verdict::join`, because doing so would break the absorption/idempotence lattice
laws and double-count evidence arriving at a node by two diamond paths. Instead,
corroboration fusion SHALL run inside a fusion node's `bind`/State channel (the
DeepCausality `Aggregatable` surface), separate from the lattice `join`. `join`
SHALL remain the idempotent LUB (`max` over the ordered fields, evidence union)
only.

#### Scenario: Identical upstream evidence reaching a node by two paths is not counted twice

- **WHEN** the same piece of upstream evidence reaches a reconvergent node along
  two distinct graph paths and the node's verdicts are combined by `join`
- **THEN** the joined verdict SHALL count that evidence exactly once (evidence
  union with de-duplication)
- **AND** the confidence SHALL be the LUB (`max`), NOT a noisy-OR combination
  that would inflate confidence by treating the two arrivals as independent

#### Scenario: Noisy-OR corroboration is confined to the fusion node

- **WHEN** genuinely independent evidence clusters are corroborated to raise
  confidence
- **THEN** that noisy-OR / inverse-variance combination SHALL be performed inside
  the fusion node's `bind`/State channel
- **AND** it SHALL NOT be performed inside `Verdict::join`

### Requirement: Cross-Domain Evidence Fusion Contract

Cross-domain fusion SHALL proceed in two steps: first cluster correlated
same-session evidence into ONE evidence unit at its representative (maximum)
confidence, then combine only ACROSS independent clusters. Both steps SHALL be
performed **closed-form on the deterministic `ConfidenceSummary { mean, variance }`
values** (no sampling). The combined summary SHALL then be materialized as an
`Uncertain::normal(mean, variance.sqrt())` **exactly once, at the CSM**, so that a
Sequential Probability Ratio Test (SPRT) — using an `UncertainParameter` with a
bounded `max_samples` of approximately 200 — can test it. Correlated same-session
evidence SHALL NOT be combined as if it were independent.

#### Scenario: DNS + resolved-IP-IOC + flow-to-IP collapse to one session cluster before combining

- **WHEN** a DNS(DGA) signal, a resolved-IP threat-intel IOC match, and a
  flow-to-that-IP signal — all belonging to the same session — are fused together
  with an independent host-runtime (Falco) signal
- **THEN** the DNS, IOC, and flow signals SHALL first collapse into a single
  session cluster at their representative (maximum) confidence
- **AND** that single session cluster SHALL then be combined only across the
  independent host-runtime cluster, and the combined result SHALL be reconstructed
  as an `Uncertain::normal(mean, sigma)` — exactly once, at the CSM — that a
  bounded SPRT (`max_samples` ~200) can test

### Requirement: Confidence Representation and Hot-Path Sampling Discipline

Confidence SHALL flow through the reasoning graph as a deterministic
`ConfidenceSummary { mean: f64 in [0,1], variance: f64 }`, not as a live
`Uncertain`. All `join` and closed-form fusion operations SHALL operate on the
summary WITHOUT sampling. An `Uncertain::normal(mean, variance.sqrt())` SHALL be
materialized exactly once per incident hypothesis — at the CSM — for the single
bounded SPRT; `expected_value` and `standard_deviation` (fixed-N, no early-exit)
MUST NOT be called on the reasoning path. Because DeepCausality's global sample
cache is process-global, unbounded, and allocates a fresh id per `Uncertain`
construction, the reasoning loop SHALL clear the whole cache
(`with_global_cache(|c| c.clear())`) at the per-tick barrier — after all incident
evaluations for the tick complete and while no SPRT is in flight — so the cache
acts as bounded per-tick scratch rather than an unbounded leak.

#### Scenario: Reconvergent join composes confidence without sampling

- **WHEN** verdicts are folded through the kill-chain graph, including reconvergent
  joins
- **THEN** every `join` and closed-form fusion step SHALL read and write only the
  `ConfidenceSummary` fields and SHALL draw zero samples
- **AND** the only `Uncertain` materialization and sampling SHALL be the single
  bounded SPRT per incident hypothesis at the CSM

#### Scenario: The DC sample cache is cleared at the tick barrier

- **WHEN** a reasoning tick finishes evaluating all incident hypotheses and no SPRT
  is in flight
- **THEN** the reasoning loop SHALL clear the whole DeepCausality global sample
  cache so the next tick starts from empty
- **AND** SPRT evaluations SHALL use a bounded `max_samples` (approximately 200),
  not the 1000-sample default

### Requirement: Causal Security Crate Family

The causal security engine SHALL be a family of flat `rust/causal-*` crates
listed as root-workspace members (mirroring `rust/anomaly-*`), comprising
`causal-model`, `causal-ports`, `causal-context`, `causal-ingest`,
`causal-causaloids`, `causal-reasoning`, `causal-mitigation`, `causal-emit`,
`causal-config`, and the `causal-engine` binary. The `causal-ports` crate SHALL
hold the boundary traits (`ObservationSource`, `ContextStore`, `Emitter`,
`MitigationPolicy`, `ActionExecutor`) that form the isolation seam between layers,
and no `crates/`/`bin/` subfolder or nested `[workspace]` SHALL be introduced.

#### Scenario: A new data source touches only causal-ingest

- **WHEN** a new collector, CNPG table, or NATS subject is added as a data source
- **THEN** the change SHALL be confined to `causal-ingest` (the only crate that
  touches `rust/srql`/NATS/CNPG)
- **AND** `causal-model`, `causal-ports`, `causal-context`, `causal-causaloids`,
  and `causal-reasoning` SHALL require no change to accommodate the new source

#### Scenario: Boundary traits live in the ports seam

- **WHEN** the in-process engine is later split into networked components
- **THEN** the isolation seam SHALL be re-implemented by re-implementing the
  `causal-ports` boundary traits
- **AND** the layer dependency order SHALL remain `causal-model` → `causal-ports`
  → {context, causaloids, reasoning, ingest, mitigation, emit, config} →
  `causal-engine` (bin), with `causal-reasoning` and `causal-causaloids` never
  depending on each other

