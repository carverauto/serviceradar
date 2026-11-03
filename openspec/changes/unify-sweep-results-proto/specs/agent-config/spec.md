# agent-config Delta

## ADDED Requirements

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
  execution, and immutable traffic class used by every `EdgeRecordV1`
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
An assignment/check/command/integration/continuous-producer capability SHALL
authorize collection only within its lease and separate host-function
permissions. The authoritative control-plane issuer MAY issue a short-lived
delivery capability for
already-spooled immutable bytes, bound to network scope, agent, traffic class, spool ID and sequence, output contract/registry, producer assignment/run,
semantic digest, stable event ID and `record_sha256`, original collection proof,
authorization context, and source/coverage/range where applicable. A delivery capability SHALL
NOT authorize a new probe, change payload identity or traffic class, or restore
domain eligibility after an assignment fence.

#### Scenario: Collection lease expires before publication
- **WHEN** an agent still has an immutable frame collected during the valid lease
- **THEN** it SHALL stop new collection immediately
- **AND** MAY request delivery-only authority to drain that exact frame

#### Scenario: Reconnecting agent drains a backlog whose production grant lapsed
- **GIVEN** an agent was disconnected past the production grant of records it
  spooled while its producer assignment stayed active
- **WHEN** it reconnects and requests delivery authority for those records
  through its gateway with their exact bytes
- **THEN** the gateway SHALL verify each record's bytes, origin, production
  grant signature and network scope against the authenticated agent before the
  issuer is asked
- **AND** the issuer SHALL return a short-lived same-spool renewal bound to each
  record's event ID, `record_sha256`, spool ID and sequence only while the
  assignment is active and held by that agent
- **AND** a record whose assignment was revoked SHALL receive no delivery
  authority

#### Scenario: Old assignment was replaced
- **GIVEN** an immutable old frame was collected before its assignment was
  fenced
- **WHEN** the authoritative control-plane issuer freshly authorizes its exact
  event-ID/`record_sha256` with a delivery-only capability after a replacement attempt
  became authoritative
- **THEN** the frame MAY be durably delivered and retained as auditable history
- **AND** SHALL NOT displace the replacement in current state, execution counts,
  completion, or any other domain-eligible projection

#### Scenario: Recovery changes spool coordinates
- **GIVEN** a journaled rollover copied an immutable event to a new spool lane
- **WHEN** old collection authority has expired or been fenced
- **THEN** replacement delivery authority SHALL bind the recovery ID, old/new
  coordinates, unchanged semantic digest, original collection proof, output
  contract/registry, producer run, network scope, traffic class, and applicable
  source/coverage/range
- **AND** the old coordinate-bound capability SHALL NOT authorize arbitrary bytes
  in the new lane
