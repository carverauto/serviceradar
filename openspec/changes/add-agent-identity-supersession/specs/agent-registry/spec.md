## ADDED Requirements

### Requirement: Superseded Agent Identities
The system SHALL mark an agent identity `superseded` when another agent uid checks in on the
same `device_uid` and the identity is no longer live, recording the replacing uid in
`superseded_by` and the time in `superseded_at`. Only a shared `device_uid` identifies two
agents as one host; a shared address or hostname MUST NOT supersede an identity. An identity
that is connected and has heartbeated within the agent timeout MUST be kept.

Every supersession, every live identity kept, and every revival MUST be recorded in
`platform.identity_decisions` with the `agent_supersession` kind, naming the device and the
agent uid.

#### Scenario: Host re-enrolls under a new agent uid
- **GIVEN** agent `agent-old` linked to device `sr:dev-1` that has stopped reporting
- **WHEN** agent `agent-new` checks in and resolves to `sr:dev-1`
- **THEN** `agent-old` SHALL have status `superseded`, `superseded_by` `agent-new` and a
  `superseded_at` time
- **AND** an `agent_supersession` decision SHALL be recorded for `sr:dev-1` with subject
  `agent-old`

#### Scenario: Previous identity was already unavailable
- **GIVEN** agent `agent-old` on `sr:dev-1` already marked `unavailable` by the stale-agent
  pruner
- **WHEN** agent `agent-new` checks in on `sr:dev-1`
- **THEN** `agent-old` SHALL be marked `superseded`

#### Scenario: Two live agents on one device
- **GIVEN** agent `agent-a` on `sr:dev-1` is connected and heartbeating
- **WHEN** agent `agent-b` checks in on `sr:dev-1`
- **THEN** `agent-a` SHALL stay connected
- **AND** an `agent_supersession` decision with reason `live_identity_kept` SHALL be recorded

#### Scenario: Different hosts behind one address
- **GIVEN** agents on two different devices that report the same source address
- **WHEN** either checks in
- **THEN** neither SHALL be superseded

#### Scenario: Existing phantoms are retired
- **GIVEN** two identities on one device, the older of which stopped reporting before this
  rule existed
- **WHEN** the hourly agent maintenance job runs
- **THEN** the older identity SHALL be superseded by the most recently seen one
- **AND** running the job again SHALL change nothing

### Requirement: Superseded Agent Revival
The system SHALL revive a superseded agent identity that reports in again under its own uid,
returning it to `connected`, clearing `superseded_by` and `superseded_at`, and recording an
`agent_supersession` decision with reason `superseded_agent_reconnected`. Any other path that would
return a superseded identity to service MUST be refused.

#### Scenario: Superseded identity heartbeats again
- **GIVEN** agent `agent-old` is superseded
- **WHEN** a gateway reports a heartbeat for `agent-old`
- **THEN** `agent-old` SHALL be `connected` with no `superseded_by`
- **AND** the revival SHALL be recorded

#### Scenario: Generic registration cannot revive
- **GIVEN** agent `agent-old` is superseded
- **WHEN** the connected-registration upsert is called for `agent-old`
- **THEN** the upsert SHALL be refused and `agent-old` SHALL stay superseded

### Requirement: Superseded Agents Leave Operational Views
SRQL `in:agents` SHALL exclude superseded agent identities by default and SHALL return them
when the query sets `include_deleted:true` or filters on `status` or `superseded_by`. Add-on
rollouts MUST NOT target a superseded agent.

#### Scenario: Default agent query
- **GIVEN** a superseded agent `agent-old` and its replacement `agent-new`
- **WHEN** a client queries `in:agents`
- **THEN** the results SHALL include `agent-new` and SHALL NOT include `agent-old`

#### Scenario: History query
- **WHEN** a client queries `in:agents status:superseded`
- **THEN** the results SHALL include `agent-old` with its `superseded_by`

#### Scenario: Rollout of a profile that still names the old identity
- **GIVEN** a profile with assignments for `agent-old` (superseded) and `agent-new`
- **WHEN** a rollout starts for the profile
- **THEN** its targets SHALL include `agent-new` only
