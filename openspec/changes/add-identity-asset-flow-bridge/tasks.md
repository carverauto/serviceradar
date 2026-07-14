# Tasks: Identity↔asset↔flow bridge, lateral-movement (S3), and counterfactual blast-radius

Phase-2 cross-domain inflection of the causal SECURITY engine. Extends the `add-causal-engine`
chassis and the `add-causal-security-detections` catalog; composes with the `service-flow-bridge`
(Gap A) `service_endpoints` mapping + `attributed_flow` rows. Host-auth fleet ingest is a SEPARATE
FUTURE CHANGE (`openspec/notes/sr-host-auth-gap.md`) — S3 is authored here but gated on its
availability.

## 1. Identity↔asset↔flow bridge (capability: identity-asset-flow-bridge)

- [ ] 1.1 Consume the `service-flow-bridge` `service_endpoints(entity, ip, port, proto)` mapping as
  the identity↔asset substrate; do NOT re-declare the table or re-derive its binding. Where the
  Phase-2 substrate needs an extension column for identity resolution, add it via an Elixir/Ash
  **platform-schema** migration (ingestion runs no DDL).
- [ ] 1.2 Project **identity-privilege edges** and **identity→asset reachability edges** into the AGE
  `platform_graph` in `network_discovery/topology_graph.ex`, composing OTEL service edges +
  `attributed_flow` rows; key every edge to canonical `sr:`-prefixed entity ids
  (`RuntimeGraph.canonical_runtime_id/1`). Additive MERGE, mirroring existing `CONNECTS_TO` /
  `MANAGED_BY` projection; no unbounded fanout (honor the carrier-scale render contract).
- [ ] 1.3 Hydrate the identity/reachability edges into the L2 Context in `rust/causal-ingest` /
  `rust/causal-context` (Spaceoid reachability + identity `Datoid`s); refresh cadence separate from
  the topology freeze.
- [ ] 1.4 Surface "privileged identity reaches a critical asset it never normally touches" as an
  evidence signal the reasoner (`rust/causal-causaloids`) can read.

## 2. Asset criticality tagging (capability: identity-asset-flow-bridge)

- [ ] 2.1 Add an asset criticality/exposure attribute (crown-jewel tier) via an Elixir/Ash
  platform-schema migration + resource; author a set/edit surface for it.
- [ ] 2.2 Project the criticality attribute onto the AGE `Device`/asset vertex (bounded scalar, no
  new vertices) and hydrate it into Context as a `Datoid`.
- [ ] 2.3 Compose criticality into `SecVerdict` severity so it RAISES (never lowers) predicted
  severity monotonically — a domain-controller incident outranks an identical print-server incident.

## 3. Counterfactual blast-radius cascade (capability: causal-attack-path-simulation)

- [ ] 3.1 Implement the blast-radius cascade in `rust/causal-reasoning`: `do(compromise = X)` via
  DeepCausality `alternate_value` value-substitution interventions (the `cascade_failure` template)
  over the frozen `platform_graph`, accumulating a compromised-set in reasoning State.
- [ ] 3.2 V1 scope = **network-tier reachability only** (AGE `platform_graph` `is_reachable`);
  service-dependency / identity-tier blast radius is deferred. Document the scope boundary.
- [ ] 3.3 Expose the computed blast-radius (compromised-set size / members) to `add-causal-mitigation`'s
  `blast_radius` gate, computed BEFORE the policy table is consulted (feeds `blast_radius_max`).
- [ ] 3.4 Note in code that `alternate_value` is counterfactual value substitution, NOT Pearl
  do()-surgery; the compose-interventions-over-carried-State pattern is the intended shape.

## 4. Lateral-movement causaloid S3 (capability: causal-attack-path-simulation)

- [ ] 4.1 Author S3 (ATT&CK **T1021**) in `rust/causal-causaloids` fusing host-auth(successful host
  login) ∧ new-internal-flow(SMB/RDP) ∧ topology(segment-cross, from the identity bridge) ∧
  target-vuln; emit into the kill-chain graph at `Stage::Lateral`.
- [ ] 4.2 **Guard S3 on host-auth availability:** when the `Auth` Observation domain has no fleet
  substrate (host-auth ingest not deployed), S3 MUST NOT fire — no console-auth false positives.
  Reference `sr-host-auth-gap.md`; host-auth ingest is a separate future change.
- [ ] 4.3 Use the identity→asset reachability + segment-boundary edges from §1 to detect the
  "login from a newly-compromised peer across a segment boundary to a vulnerable host" pattern.

## 5. Validation

- [ ] 5.1 `openspec validate add-identity-asset-flow-bridge --strict` passes (every requirement has
  ≥1 `#### Scenario:`; exact `## ADDED Requirements` headers).
- [ ] 5.2 New Rust crates build under Bazel (`all_crate_deps`) and `cargo`; DB changes are Elixir/Ash
  platform-schema migrations only (ingestion runs no DDL).
- [ ] 5.3 Cross-references verified present in `proposal.md`: `add-causal-security-detections`,
  `add-causal-security-foundation`, `add-causal-engine`, `add-causal-mitigation`,
  `add-causal-detection-feedback`, and the deferred host-auth track (`sr-host-auth-gap.md`).
