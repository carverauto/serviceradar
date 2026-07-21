# agent-config Delta

## ADDED Requirements

### Requirement: Compiled config selects result format explicitly
Agent configuration SHALL carry an explicit result format for new sweep and MTR
executions, scoped by authoritative `network_scope_id`/site, agent/cohort,
execution, and rollout generation. Before result-path cutover, the compiler
SHALL enforce a minimum dual-path agent/gateway version that supports both
independently acknowledged bounded legacy frames and `edge_results_v1`. It
SHALL select v1 only when that version gate and the complete installation-local
gateway, stream, and consumer path are compatible. Agents below the gate SHALL
receive no new sweep or MTR work; the installation SHALL NOT create an
unpatched-agent compatibility bridge or introduce tenant/account/cell routing
axes.

#### Scenario: Cohort is enabled for v1
- **GIVEN** the agent satisfies the minimum dual-path version, advertises v1,
  and its installation-local result path is ready
- **WHEN** the rollout includes its cohort
- **THEN** compiled config SHALL select `edge_results_v1` for new executions
- **AND** record the selection and rollout generation for audit

#### Scenario: Agent is below the dual-path minimum
- **WHEN** an agent or reachable gateway is below the configured minimum
  dual-path version
- **THEN** the compiler SHALL stop assigning new sweep and MTR work to that
  agent
- **AND** SHALL require upgrade rather than route the work through an unpatched
  compatibility bridge

#### Scenario: Config hash changes for an unrelated reason
- **WHEN** compiled content changes without changing the explicit result-format
  field
- **THEN** the agent SHALL keep the configured result format
- **AND** SHALL NOT treat hash inequality as a protocol switch

### Requirement: Sweep assignments use signed bounded collection capabilities
The config/control plane SHALL deliver a scheduler-signed collection capability
bound to authoritative `network_scope_id`/site, agent, execution plan,
shard/range, assignment epoch, immutable traffic class, config generation, and
expiry. Traffic class SHALL be scheduler-selected as `bulk` or `interactive`,
never accepted from an unsigned caller priority. Every gateway SHALL verify it
locally, while revocation or fence generations SHALL propagate through bounded
control/config state. The canonical signing contract SHALL include version,
issuer, algorithm, key ID, not-before/expiry, and stable claims; normal verifier
overlap SHALL cover the maximum spool/offline/replay/rollback horizon.

#### Scenario: Assignment is delivered
- **WHEN** the scheduler assigns a v1 shard range to an agent
- **THEN** the immutable plan/range digest and signed capability SHALL be
  included in its assignment
- **AND** the capability SHALL bind the authoritative network scope, agent,
  execution, and immutable traffic class used by every result frame
- **AND** no full target list SHALL be repeated in result batches

#### Scenario: Assignment is revoked and replaced
- **WHEN** ownership moves to a replacement agent
- **THEN** the prior capability SHALL expire or be fenced before the replacement
  becomes authoritative
- **AND** the new capability SHALL carry a higher scheduler-issued epoch

#### Scenario: Gateway has stale fence state
- **GIVEN** a signature is valid but its generation has been revoked
- **WHEN** a gateway has not yet observed the fence
- **THEN** an already published event MAY remain auditable
- **AND** the authoritative consumer SHALL recheck scheduler state and prevent
  stale data from changing reconciled state

#### Scenario: Signing key rotates with queued frames
- **WHEN** a normal key rotation occurs while valid observations remain spooled
  or in JetStream
- **THEN** old verification state SHALL remain through their supported horizon or
  the scheduler SHALL issue delivery-only reauthorization from retained assignment
  records before retirement
- **AND** compromise revocation SHALL fail closed, quarantine/audit affected data,
  and recollect coverage under a new epoch rather than blindly re-sign it

### Requirement: Collection and spool-drain authority are separate
An assignment/check/command capability SHALL authorize collection only within
its lease. The scheduler MAY issue a short-lived delivery capability for
already-spooled immutable bytes, bound to network scope, agent, traffic class,
lane, spool ID and sequence, semantic digest, stable event ID/checksum, original
collection proof, authorization context, and range. A delivery capability SHALL
NOT authorize a new probe, change payload identity or traffic class, or restore
domain eligibility after an assignment fence.

#### Scenario: Collection lease expires before publication
- **WHEN** an agent still has an immutable frame collected during the valid lease
- **THEN** it SHALL stop new collection immediately
- **AND** MAY request delivery-only authority to drain that exact frame

#### Scenario: Old assignment was replaced
- **GIVEN** an immutable old frame was collected before its assignment was
  fenced
- **WHEN** the scheduler freshly authorizes its exact event/checksum with a
  delivery-only capability after a replacement attempt became authoritative
- **THEN** the frame MAY be durably delivered and retained as auditable history
- **AND** SHALL NOT displace the replacement in current state, execution counts,
  completion, or any other domain-eligible projection

#### Scenario: Recovery changes spool coordinates
- **GIVEN** a journaled rollover copied an immutable event to a new spool lane
- **WHEN** old collection authority has expired or been fenced
- **THEN** replacement delivery authority SHALL bind the recovery ID, old/new
  coordinates, unchanged semantic digest, original collection proof, network
  scope, traffic class, and range
- **AND** the old coordinate-bound capability SHALL NOT authorize arbitrary bytes
  in the new lane
