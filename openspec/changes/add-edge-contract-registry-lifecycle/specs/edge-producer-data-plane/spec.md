# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: Record cost is calculated by trusted platform code
Producer-supplied cost, count, or expansion hints SHALL be non-authoritative.
For each contract, the immutable registry bundle SHALL contain a deterministic
platform-owned validator and cost-model version. Before spool acceptance, the
agent SHALL compute a conservative trusted row/write-byte charge from canonical
bytes or reserve the contract's fixed maximum. The gateway SHALL validate that
trusted charge against the active bundle and grant without treating opaque
caller fields as authority. After decode and before credit refund or side
effects, EventWriter SHALL recompute actual bounded cost with the same model.
Unknown models, arithmetic overflow, nondeterministic results, or actual cost
above the trusted bound SHALL fail before partial projection.

#### Scenario: A plugin underdeclares database cost
- **WHEN** a plugin claims one row but its approved payload deterministically
  expands to more rows or write bytes
- **THEN** the agent SHALL replace the claim with the trusted conservative charge
  or reject the record before local acceptance
- **AND** EventWriter SHALL independently detect any remaining mismatch before
  writing domain state

#### Scenario: EventWriter lacks the cost model
- **GIVEN** a record is otherwise valid under a contract bundle
- **WHEN** EventWriter cannot load the exact cost-model version
- **THEN** that deployment SHALL be not ready or paused for the contract
- **AND** the record SHALL NOT fall back to producer estimates or generic
  projection

### Requirement: Output contract bundles have a governed deployment lifecycle
The deployment SHALL govern output-contract bundles through a signed lifecycle, and SHALL NOT let a partially deployed or stale epoch receive production.

The RECORD-SIDE reference -- contract ID/version, bundle digest, registry epoch,
registry-snapshot digest, effective-grant digest -- is frozen by the
edge record v1 wire ABI change. This requirement owns the registry and its
operation.

The deployment SHALL maintain a versioned output-contract registry shared by
assignment compilation, the agent sink, gateway readiness/routing, and
EventWriter. An immutable contract bundle SHALL bind contract ID/version,
encoding and schema canonicalization, unknown-field policy, bounded validator,
authoritative-field rules, deterministic domain identity and revision/merge
semantics, platform partition rule, cost model, projector engine/configuration,
retention/data classification, and error policy. Its exact digest and registry
epoch SHALL be bound into every accepted record and retained through the maximum
producer-retry, agent-offline, spool, JetStream replay, DLQ, and redrive horizon.

Package metadata MAY request approved outputs and declarative processor
contributions, but SHALL NOT choose subjects, streams, consumers, traffic class,
database tables/DDL, executable Core processors, or arbitrary subject filters.
A producer grant SHALL become ready only when agent, gateway, route map, and
required projector have compatible registry state.

Each bundle SHALL transition through signed `candidate`, `ready`, `active`,
`draining`, and `retired` states or the terminal `security-revoked` state. A
candidate SHALL become ready only after the target agent cohort, every
authoritative gateway route/map generation, and every required EventWriter
validator, cost engine, and projector attest the exact bundle digest. Assignment
compilation SHALL issue grants only for one atomically selected active epoch; a
partially deployed or stale epoch SHALL NOT receive new production. Planned
retirement SHALL stop new grants and permit only exact historical backlog to
drain to declared spool, JetStream, DLQ, redrive, and producer-receipt
watermarks. Security revocation SHALL stop both new production and backlog
delivery fail-closed until an approved safe replacement, redrive, or explicit
waiver exists. Registry history SHALL be garbage-collected only after all of its
declared horizons and correctness holds close.

#### Scenario: Package requests an unapproved output
- **WHEN** a package requests or submits a contract absent from its effective
  assignment grant
- **THEN** the agent SHALL reject it before local spool acceptance
- **AND** no fallback generic JSON, subject, or dynamic database projection
  SHALL be created

#### Scenario: Deployment components disagree on registry epoch
- **GIVEN** the agent can encode a contract but the gateway route or EventWriter
  projector is not ready for its exact bundle
- **WHEN** the scheduler evaluates a new producer assignment
- **THEN** the assignment SHALL remain not ready or paused
- **AND** the mismatch SHALL NOT be converted into a fleet-wide poison stream

#### Scenario: Candidate activation is only partially ready
- **GIVEN** an agent and gateway route report a candidate bundle ready
- **AND** one required EventWriter projector or route-map generation is not ready
- **WHEN** the control plane evaluates activation
- **THEN** the active registry epoch SHALL remain unchanged
- **AND** no assignment SHALL receive a grant for the candidate bundle

#### Scenario: A contract is retired normally
- **WHEN** a newer contract version replaces an old version without a security
  incident
- **THEN** new grants SHALL use the new bundle while immutable old backlog MAY
  drain through the pinned historical bundle
- **AND** the historical bundle SHALL remain resolvable until all supported
  retry/replay/redrive horizons close

#### Scenario: A contract is revoked for compromise
- **WHEN** a contract, package, validator, or projector is security-revoked
- **THEN** new production and delivery of matching records SHALL stop fail-closed
- **AND** matching backlog SHALL be held or quarantined until an operator
  authorizes a fixed safe bundle, redrive, or explicit waiver

#### Scenario: A stale component resumes after activation
- **WHEN** a gateway, agent, or EventWriter instance resumes with an epoch older
  than the active or explicitly draining set
- **THEN** it SHALL be fenced from new production and authoritative projection
- **AND** it SHALL NOT roll the deployment backward or reinterpret records under
  its local latest-known bundle

