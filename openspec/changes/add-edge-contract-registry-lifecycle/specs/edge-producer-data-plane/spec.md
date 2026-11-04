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
A producer grant SHALL be issued only under the active epoch, which every live
core node and agent gateway already holds.

Each registry epoch SHALL be signed and SHALL transition through `candidate`,
`active`, `draining`, and `retired` states; a bundle MAY additionally enter the
terminal `security-revoked` state. There SHALL be no separate `ready` state. Core
derives each epoch from the release contract catalog, and agents SHALL NOT hold
the registry: an agent only holds capabilities that reference an epoch and
bundle. A candidate SHALL become active only after every live core node reports
the candidate's digest as its catalog digest and every live agent gateway
reports having installed a registry document that contains the candidate.
Activation SHALL NOT be forced on a timeout. At most one non-retired candidate
SHALL exist; a candidate superseded by a newer one, or matched by no live core
node for a full capability-lifetime window, SHALL be retired without ever being
activated, and SHALL never sign anything. Assignment compilation SHALL issue
grants only for one atomically selected active epoch; a partially deployed or
stale epoch SHALL NOT receive new production. Planned retirement SHALL stop new
grants and permit only exact historical backlog to drain under its own epoch's
bundles until the epoch's retirement time. Security revocation SHALL stop both
new production and backlog delivery fail-closed until an approved safe
replacement, redrive, or explicit waiver exists. Registry history SHALL be
garbage-collected only after all of its declared horizons and correctness holds
close.

#### Scenario: Package requests an unapproved output
- **WHEN** a package requests or submits a contract absent from its effective
  assignment grant
- **THEN** the agent SHALL reject it before local spool acceptance
- **AND** no fallback generic JSON, subject, or dynamic database projection
  SHALL be created

#### Scenario: Deployment components disagree on registry epoch
- **GIVEN** a candidate epoch that one live gateway has not installed, or that
  one live core node's catalog does not match
- **WHEN** core evaluates activation
- **THEN** the active epoch SHALL remain unchanged
- **AND** no agent SHALL receive a grant or lease signed under the candidate
- **AND** the mismatch SHALL NOT be converted into a fleet-wide poison stream

#### Scenario: Agents do not gate activation
- **GIVEN** every live core node and every live gateway holds a candidate epoch
- **WHEN** core evaluates activation
- **THEN** core SHALL activate the candidate without waiting on any agent
- **AND** agents SHALL receive capabilities signed under it on their next config
  poll

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
- **WHEN** a gateway or core node resumes with an epoch older than the active
  or explicitly draining set
- **THEN** it SHALL NOT sign under its own epoch, insert or claim a candidate, or
  count toward activation readiness
- **AND** a core node SHALL sign under the active epoch only for entries whose
  exact bundle digest its own catalog holds
- **AND** a record SHALL be projected by any core node whose catalog holds the
  same contract id and version at a `projection_revision` greater than or equal
  to the record's bundle revision
- **AND** records no live core node can project SHALL be held as
  `awaiting_roll_forward` (grants revoked, retryable gateway refusal, bulk-stream
  backlog dead-lettered with original bytes and redriven), never rejected; a
  dead-letter overflow during the gateways' refresh window SHALL be counted,
  alerted and reported as `awaiting_roll_forward_overflow`
- **AND** it SHALL NOT roll the deployment backward or reinterpret records under
  its local latest-known bundle
