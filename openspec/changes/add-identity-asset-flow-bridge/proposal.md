# Change: Identity↔asset↔flow bridge, lateral-movement detection, and counterfactual blast-radius

## Why

The causal security engine's highest-leverage gap is the absence of a graph of *which identity can reach which asset* and *which assets are crown jewels* — without it, lateral-movement (S3) is undetectable and verdict severity is ungrounded (§7 gap #1, §6 S3). This change is the Phase-2 cross-domain inflection: it adds the identity↔asset↔flow bridge and asset-criticality grounding, ships the S3 lateral-movement causaloid (guarded on the deferred host-auth track), and computes network-tier counterfactual blast-radius so mitigation can gate on predicted impact.

## What Changes

- **ADD capability `identity-asset-flow-bridge`:** model identity→asset reachability in the AGE `platform_graph` by consuming the service-flow-bridge's `service_endpoints(entity, ip, port, proto)` mapping plus `attributed_flow` rows and projecting **net-new identity-privilege edges**; tag crown-jewel assets so an unusual privileged-identity→critical-asset reach is surfaced.
- **ADD asset criticality/exposure attribute** consumed by the engine as a Context `Datoid`, so verdict severity is grounded (a domain-controller incident outranks a print-server incident). DB changes land via Elixir/Ash **platform-schema migrations**; ingestion runs no DDL.
- **ADD capability `causal-attack-path-simulation`:** compute attack blast-radius by a counterfactual `alternate_value` cascade over `platform_graph` reachability (**network-tier only in V1**), accumulating a compromised-set in reasoning State, and expose the result to the mitigation `blast_radius` gate (evaluated before the policy is consulted).
- **Ship security causaloid `S3` (lateral movement, ATT&CK T1021)** fusing host-auth ∧ new-internal-flow(SMB/RDP) ∧ topology segment-cross ∧ target-vuln. S3 is **guarded on host-auth availability** and MUST NOT fire on console-only auth; host-auth fleet ingest is a **separate deferred track** (`openspec/notes/sr-host-auth-gap.md`), not authored here.
- Not **BREAKING** — additive AGE edges and platform-schema attributes; the engine chassis and `SecVerdict` are inherited, not redefined.

## Impact

- **Affected specs:** `identity-asset-flow-bridge` (ADDED), `causal-attack-path-simulation` (ADDED).
- **Affected code:** `rust/causal-context` (identity + criticality `Datoid`s, compromised-set State), `rust/causal-causaloids` (S3), `rust/causal-reasoning` (blast-radius cascade over the frozen `platform_graph`), `rust/causal-ingest` (identity-privilege / reachability edge hydration), Elixir/Ash **platform-schema migrations** (extend `service_endpoints`, identity-privilege edges, asset-criticality attribute), `network_discovery/topology_graph.ex` (AGE `platform_graph` projection of identity/reachability edges).
- **Dependencies / Coordinate:** DEPENDS ON `add-causal-security-detections` (the `SecVerdict` lattice, kill-chain `CausaloidGraph`, and S-catalog framing), which itself builds on `add-causal-security-foundation`. COMPOSES WITH `add-causal-engine`'s `service-flow-bridge` (Gap A — OTEL service edges, `service_endpoints`, and `attributed_flow` rows): this change consumes that substrate and MUST NOT re-derive flow attribution or the service-endpoint binding. The computed blast-radius is consumed by `add-causal-mitigation`'s `blast_radius_max` policy gate. S3 is additionally gated on the deferred host-auth ingest track (`sr-host-auth-gap.md`, a future separate change). S3 detections feed `add-causal-detection-feedback`. AGE graph = `platform_graph`; entity IDs are canonical `sr:`-prefixed (`RuntimeGraph.canonical_runtime_id/1`).
