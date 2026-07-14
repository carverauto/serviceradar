# Design — add-identity-asset-flow-bridge

## Context

This change is Phase 2 of the causal SECURITY engine (design note
`openspec/notes/sr-causal-engine.md` §4.6, §6 S3, §7 gaps #1/#2/#5, §9 Phase 2). It EXTENDS the
settled `add-causal-engine` chassis (fused `rust/causal-*` crates, three ingestion feeds, emission
on `signals.analytics.predictions.>` → `AnalyticsSignals`, entity-ID reuse) and the
`add-causal-security-detections` catalog (the `SecVerdict` lawful lattice, the kill-chain
`CausaloidGraph`, and security causaloids S1/S2/S4/S5/S6). It does NOT redefine those.

The engine's single biggest security gap (§7 gap #1) is that there is **no graph of which identity
can reach which asset**, and **no notion of which assets are crown jewels**. Two consequences:

- **S3 (lateral movement) cannot fire.** Its defining leg — a successful login on host B initiated
  from host A across a segment boundary to a vulnerable target — needs both host-auth events (§7 gap
  #2, deferred) and an identity↔asset reachability model (this change).
- **Verdict severity is ungrounded.** Without asset criticality, an incident on a domain controller
  and one on a print server look identical to the `SecVerdict::join` severity LUB.

The substrate this builds on already exists in-flight: `add-causal-engine`'s `service-flow-bridge`
(Gap A) derives OTEL service edges, introduces the `service_endpoints(service_id, listen_ip,
listen_port, protocol)` mapping, and consumes `attributed_flow` rows
(`ocsf_network_activity.ocsf_payload.event_type = "attributed_flow"`). This change **composes** that
substrate and adds only the identity layer on top.

## Goals / Non-Goals

Goals:

- Model **identity→asset reachability** in the AGE `platform_graph` by composing the
  `service_endpoints` mapping + `attributed_flow` rows with net-new **identity-privilege edges**,
  keyed to canonical `sr:`-prefixed ids.
- Ground severity with an **asset criticality/exposure** attribute consumed as a Context `Datoid`.
- Ship **S3** (T1021), guarded on host-auth availability.
- Compute **network-tier counterfactual blast-radius** and expose it to the mitigation gate.

Non-Goals (this change):

- **Host-auth fleet ingest.** SSH/RDP/Windows/PAM/RADIUS authentication ingest is a SEPARATE
  deferred track (`sr-host-auth-gap.md`, its own future OpenSpec change). S3 is authored here but
  no-ops until that substrate lands.
- **Re-deriving flow attribution or the service-endpoint binding.** Owned by `add-causal-engine`'s
  `service-flow-bridge` + the in-flight attributed-flow correlation; consumed, not rebuilt.
- **Service-dependency / identity-tier blast radius.** V1 blast-radius is network-tier reachability
  only; the service/identity tier is a later phase once the identity graph matures.
- **The mitigation policy table / actuation.** Owned by `add-causal-mitigation`; this change only
  produces the `blast_radius` value its `blast_radius_max` predicate reads.

## Decisions

### Decision 1 — Compose `service_endpoints`, do not redefine it

The identity bridge CONSUMES the `service-flow-bridge` `service_endpoints(entity, ip, port, proto)`
mapping as the (identity/service)↔endpoint substrate and adds only identity-privilege and
identity→asset reachability edges. If Phase-2 identity resolution needs an extra column, it is added
by an Elixir/Ash **platform-schema** migration extending the existing table — never a parallel
table, never DDL from ingestion.

Alternatives considered: a fresh identity-endpoint table (rejected — duplicates the mapping and
forks two evolving schemas); projecting identity as new AGE vertices with unbounded fanout (rejected
— violates the carrier-scale render contract; bounded edges/scalars on existing vertices carry the
signal).

### Decision 2 — Asset criticality is a Context `Datoid`, and only RAISES severity

Criticality/exposure is stored as a platform-schema attribute, projected as a bounded scalar onto
the asset/`Device` vertex, hydrated into Context as a `Datoid`, and composed into `SecVerdict`
severity **monotonically upward** (mirrors the chassis `raise_severity_to` pattern for device risk).
This preserves the lattice laws of `SecVerdict::join` (severity is still a LUB) while letting a
domain-controller incident outrank a print-server incident.

Alternatives considered: encoding criticality directly into the `join` lattice ordering (rejected —
entangles asset value with kill-chain stage/confidence and breaks absorption/idempotence); a
free-text tag (rejected — not comparable for severity grounding).

### Decision 3 — Blast-radius via `alternate_value` cascade, network-tier V1, gate-before-decide

Blast radius is a counterfactual `do(compromise = X)` run forward over the frozen `platform_graph`
using DeepCausality `alternate_value` value-substitution interventions (the `cascade_failure`
template), accumulating a compromised-set in reasoning State. V1 scope is **network-tier
reachability only** (`is_reachable` over `platform_graph`). The result is computed BEFORE the
mitigation policy is consulted so `add-causal-mitigation`'s `blast_radius_max` predicate can gate
auto-fire on predicted impact. `alternate_value` is counterfactual value substitution, NOT Pearl
do()-surgery — the compose-interventions-over-carried-State pattern is correct and sufficient for
blast radius.

Alternatives considered: Pearl-style graph surgery (rejected — DC does not offer it and it is
unnecessary for reachability cascade); computing blast radius after the policy fires (rejected — the
gate needs the value up front).

### Decision 4 — S3 is guarded on host-auth availability

S3 is authored here so the kill-chain graph has its `Stage::Lateral` node, but it is **guarded**: if
the `Auth` Observation domain has no fleet substrate (host-auth ingest not deployed), S3 does not
fire, preventing console-auth false positives. When the deferred host-auth track lands, S3 upgrades
from ⚠️ to ✅ with no engine rework.

Alternatives considered: deferring S3 entirely until host-auth ships (rejected — the identity bridge
and segment-cross detection are ready now, and shipping the guarded causaloid de-risks the later
host-auth cutover); firing S3 on console auth (rejected — false positives, per the review demotion
of S7/S3 to ⚠️).

## Risks / Trade-offs

- **S3 dead until host-auth lands.** → Guard keeps it inert and false-positive-free; the rest of
  this change (identity bridge, criticality, blast-radius) delivers value independently.
- **AGE fanout from identity edges.** → Bounded, canonical-id-keyed edges only; honor the
  `refactor-topology-read-model-for-carrier-scale` render contract; no per-package/per-flow vertices.
- **Blast-radius on the hot path.** → Run over the frozen CSR `platform_graph`; keep DC's
  fixed-cost `expected_value`/`standard_deviation` off the cascade; clear the process-global sample
  cache per tick (chassis Open Question Q6).
- **Criticality drift.** → Give the criticality `Datoid` a refresh cadence separate from the
  topology freeze so stale values do not pin severity.

## Migration Plan

1. Land the Elixir/Ash platform-schema migrations (asset-criticality attribute; any
   `service_endpoints` extension column) — additive, reversible.
2. Add the AGE `platform_graph` identity-privilege / reachability edge projection in
   `topology_graph.ex` (additive MERGE; no change to existing edges).
3. Hydrate identity/criticality into Context; compose criticality into severity.
4. Ship the blast-radius cascade and wire its output to the mitigation gate.
5. Author S3 behind the host-auth availability guard (inert until the deferred track lands).

Rollback: each step is additive and independently revertible; the guard means S3 never affects
verdicts until host-auth exists.

## Open Questions

- **Identity granularity.** Are identities modeled per-principal (user/service account) only, or
  also per-session? Sets the identity-privilege edge cardinality.
- **Segment-boundary source.** Does "segment cross" derive purely from AGE topology position
  (Spaceoid), or does it need an explicit VLAN/subnet segmentation attribute?
- **Crown-jewel authoring.** Operator-declared criticality vs. inferred (from reachability
  centrality / data-classification signals) — V1 assumes operator-declared; inference is later.
- **Blast-radius tier upgrade.** When the service/identity-dependency graph matures, does blast
  radius switch tiers automatically or stay network-tier until explicitly flipped?
