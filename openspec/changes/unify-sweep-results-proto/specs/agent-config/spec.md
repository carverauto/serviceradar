# agent-config Delta

## ADDED Requirements

### Requirement: Compiled config selects edge-record protocol explicitly
Agent configuration SHALL carry an explicit edge-record format and effective
output-contract grant for every new durable producer run, scoped by authoritative
`network_scope_id`/site, agent/cohort, producer assignment/run, and rollout
generation. Before result-path cutover, the compiler
SHALL enforce a minimum agent/gateway version that supports the selected
`edge_results_v1` protocol, retained spool reader, and contract registry. It
SHALL select v1 only when that version gate and the complete installation-local
gateway, stream, registry, and consumer path are compatible. Agents below the
gate SHALL receive no new affected durable work; the installation SHALL NOT create an
unpatched-agent compatibility bridge or introduce tenant/account/cell routing
axes.

#### Scenario: Cohort is enabled for v1
- **GIVEN** the agent satisfies the minimum edge-record version, advertises v1,
  and its installation-local result path is ready
- **WHEN** the rollout includes its cohort
- **THEN** compiled config SHALL select `edge_results_v1` and the exact output
  grant/registry epoch for new runs
- **AND** record the selection and rollout generation for audit
- **AND** SHALL NOT select new legacy JSON emission for that cohort

#### Scenario: Agent is below the edge-record minimum
- **WHEN** an agent or reachable gateway is below the configured minimum
  v1 protocol, spool-reader, or contract-registry version
- **THEN** the compiler SHALL stop assigning new affected durable work to that
  agent
- **AND** SHALL require upgrade rather than route the work through an unpatched
  compatibility bridge

#### Scenario: Rollout is disabled after cutover
- **WHEN** operators disable a cohort while compatible v1 spool backlog remains
- **THEN** the compiler SHALL stop assigning new affected durable work
- **AND** the installation SHALL retain compatible v1 drain consumers and SHALL
  NOT generate new legacy output as rollback

#### Scenario: Config hash changes for an unrelated reason
- **WHEN** compiled content changes without changing the explicit edge-record
  protocol, registry, or output grant
- **THEN** the agent SHALL keep the configured protocol and pinned grant
- **AND** SHALL NOT treat hash inequality as a protocol switch

### Requirement: Producer assignments contain effective output grants
The config/control plane SHALL compile package requests and platform producer
definitions into immutable effective output grants. Each grant SHALL bind exact
contract bundle/version/digest and registry epoch, package digest, host-issued
producer assignment/run authority, authorization mode and source/coverage scope,
platform route profile, immutable traffic class, record/frame/run/rate/
outstanding-spool/idempotency bounds, cost model, and retirement/revocation
state. Continuous telemetry, checks, integrations, commands, and scans SHALL use
explicit authorization variants rather than inventing a sweep range. Output
permission SHALL remain separate from network, HTTP, credential, filesystem,
command, and probe capabilities.

#### Scenario: Package requests output absent from its grant
- **WHEN** a plugin submits a contract not present in its compiled assignment
- **THEN** the agent sink SHALL reject it before durable spool acceptance
- **AND** SHALL NOT infer authority from the package manifest alone

#### Scenario: Continuous producer has no sweep range
- **GIVEN** an agent sysmon or approved continuous producer has a valid
  assignment/source grant but no target range
- **WHEN** it emits a bounded epoch record
- **THEN** the gateway and EventWriter SHALL validate the explicit continuous
  authorization variant
- **AND** SHALL NOT require or fabricate sweep execution/range claims

#### Scenario: One producer exhausts its grant
- **WHEN** a plugin reaches its record/rate/outstanding-spool bound
- **THEN** new output from that assignment SHALL receive bounded backpressure or
  rejection according to the grant
- **AND** another producer and the reserved recovery lane SHALL continue within
  the global filesystem budget

#### Scenario: Registry epoch changes
- **WHEN** config compilation activates a new registry epoch
- **THEN** new runs SHALL use grants compiled for the new epoch
- **AND** existing immutable records SHALL drain under their retained historical
  bundle unless a security revocation holds them fail-closed

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
