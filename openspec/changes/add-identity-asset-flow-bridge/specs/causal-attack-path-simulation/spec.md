# causal-attack-path-simulation Specification

## ADDED Requirements

### Requirement: Counterfactual Blast-Radius

The engine SHALL compute attack blast radius by a counterfactual cascade over `platform_graph`
reachability, using DeepCausality `alternate_value` value-substitution interventions (the
`cascade_failure` template) and accumulating a compromised-set in reasoning State. The V1 scope
SHALL be network-tier reachability only (AGE `platform_graph` `is_reachable`); service-dependency
and identity-tier blast radius are deferred to a later phase. The computed blast-radius (the
compromised-set members and size) SHALL be exposed to the mitigation `blast_radius` gate — the
`blast_radius_max` predicate of `add-causal-mitigation`'s policy table — and SHALL be computed
BEFORE that policy is consulted. `alternate_value` SHALL be treated as counterfactual value
substitution, NOT Pearl do()-surgery.

#### Scenario: do(compromise = host X) yields the reachable-host set before the attacker moves

- **WHEN** the engine runs `do(compromise = host X)` forward as a counterfactual cascade over the
  frozen `platform_graph`
- **THEN** it SHALL return the set of hosts reachable from X (network-tier), accumulated as the
  compromised-set in State, representing the blast radius BEFORE the attacker actually moves
- **AND** each member of the set SHALL be referenced by its canonical `sr:`-prefixed identity

#### Scenario: Blast-radius gates auto-fire before the policy decides

- **WHEN** a verdict is about to be evaluated against the mitigation policy table
- **THEN** the blast-radius SHALL already be computed and exposed so the `blast_radius_max`
  predicate can gate auto-fire on predicted impact
- **AND** a verdict whose predicted blast-radius exceeds the policy's `blast_radius_max` SHALL NOT
  be auto-fired by that rule

### Requirement: Lateral-Movement Detection (S3)

The engine SHALL provide security causaloid S3 (ATT&CK **T1021**) that fuses host-auth (a successful
host login) ∧ new-internal-flow (SMB/RDP) ∧ topology segment-cross ∧ target-vuln, emitting into the
kill-chain graph at `Stage::Lateral`. S3 SHALL depend on BOTH the separate host-auth ingest track
(`openspec/notes/sr-host-auth-gap.md`, a future change NOT authored here) AND this identity↔asset↔flow
bridge for its segment-cross and reachability legs. S3 SHALL be guarded on host-auth availability:
when the `Auth` Observation domain has no fleet substrate, S3 MUST NOT fire, so console-only
authentication never produces a lateral-movement false positive.

#### Scenario: Login from a newly-compromised peer across a segment boundary to a vulnerable host raises S3

- **WHEN** a successful host login originates from a newly-compromised peer, traverses a segment
  boundary (per the identity-bridge topology), targets a vulnerable host, and is accompanied by a
  new internal SMB/RDP flow
- **THEN** S3 SHALL raise a lateral-movement verdict at `Stage::Lateral` tagged ATT&CK T1021
- **AND** the verdict evidence SHALL reference the host-auth, flow, segment-cross, and vuln legs

#### Scenario: S3 is inert when host-auth fleet data is unavailable

- **WHEN** the `Auth` Observation domain has no host/fleet substrate (host-auth ingest not deployed)
- **THEN** S3 SHALL NOT fire, regardless of console-only authentication activity
- **AND** the guard SHALL prevent any lateral-movement verdict grounded solely in ServiceRadar
  console auth
