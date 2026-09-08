## ADDED Requirements

### Requirement: Native add-on update policy is visible and explicit
The native add-on assignment and profile UI SHALL show whether desired versions are
manually pinned or track the latest approved eligible package. Signed, verified
first-party packages SHALL visibly default to managed tracking; other origins SHALL
default to manual pin. The UI SHALL allow an authorized operator to pin any source or
opt a non-first-party source into tracking after reviewing canary, batch, soak, timeout,
failure-tolerance, release-channel, provenance, and capability-ceiling settings.

#### Scenario: Existing first-party profile shows managed tracking
- **GIVEN** an existing add-on profile using signed, verified first-party version `0.2.22`
- **AND** no explicit operator pin is recorded
- **WHEN** an operator opens the profile
- **THEN** the UI SHALL show `track_latest_approved` and stable version `0.2.22`
- **AND** SHALL explain that a newer eligible approved version will use a staged rollout

#### Scenario: Operator pins a managed first-party profile
- **GIVEN** a first-party profile on `track_latest_approved`
- **WHEN** an authorized operator selects `manual_pin` and saves version `0.2.22`
- **THEN** the UI SHALL show the explicit pin and exclude that source from automatic candidates
- **AND** future package approvals SHALL NOT change its desired version

#### Scenario: Operator opts into latest-approved tracking
- **GIVEN** an authorized operator editing a manually pinned non-first-party source
- **WHEN** they select `track_latest_approved`
- **THEN** the UI SHALL require a release channel, capability ceiling, canary size, batch size, soak, timeout, and tolerated-failure policy
- **AND** SHALL summarize the currently eligible target count before saving

#### Scenario: Approval previews track impact without hiding the boundary
- **GIVEN** a staged package that is a candidate for opted-in track policies
- **WHEN** an operator reviews it for approval
- **THEN** the UI SHALL show the number of sources and estimated targets that may create rollouts after approval
- **AND** SHALL state that approval makes the package eligible while rollout is a separate audited operation

### Requirement: Operators can bulk upgrade native add-on sources safely
For an approved native add-on candidate, the UI SHALL provide an authorized bulk
upgrade workflow for authoritative direct assignments and add-on profiles. The
workflow SHALL preview compatible, incompatible, directly overridden, unavailable,
ephemeral, unresolved, and already-current targets, accept rollout controls, and start
an `AddonRollout` rather than bulk-updating materialized assignments.

#### Scenario: Bulk upgrade previews authoritative sources
- **GIVEN** a newer approved add-on package and a mix of direct and profile-owned assignments
- **WHEN** an operator opens the bulk upgrade workflow
- **THEN** targets SHALL be grouped by their authoritative direct assignment or profile
- **AND** directly overridden profile targets and incompatible targets SHALL be excluded with reasons
- **AND** unavailable and ephemeral targets SHALL be counted separately before execution

#### Scenario: Starting an upgrade creates a canary rollout
- **GIVEN** an operator has selected sources and configured one canary followed by batches of ten
- **WHEN** they confirm the upgrade
- **THEN** the UI SHALL create and navigate to a rollout record
- **AND** SHALL NOT present the action as an immediate all-fleet assignment rewrite

#### Scenario: Up-to-date sources are not rewritten
- **GIVEN** selected sources that already use the candidate package
- **WHEN** the bulk upgrade preview runs
- **THEN** those sources SHALL be shown as already current
- **AND** SHALL NOT receive redundant rollout targets

### Requirement: Native add-on rollout progress and recovery are operable
The UI SHALL show rollout lifecycle state, source promotion state, current and pending
batches, per-target desired/observed versions, evidence age, health-gate result, and
full errors. Authorized operators SHALL be able to pause, resume, cancel, retry a
blocked candidate, roll back failed targets, or roll back the entire rollout.

#### Scenario: Health-gate failure stops the next batch visibly
- **GIVEN** a canary target that fails artifact verification and is rolled back
- **WHEN** the operator opens rollout detail
- **THEN** the rollout SHALL be shown paused before the next batch
- **AND** the target SHALL show candidate version, previous version, failure reason, rollback state, and evidence timestamps

#### Scenario: Paused rollout can be rolled back
- **GIVEN** a rollout with successful and failed targets that is paused
- **WHEN** an authorized operator chooses whole-rollout rollback and confirms impact
- **THEN** the UI SHALL show every affected target returning to its stable source package
- **AND** SHALL retain the rollout history after rollback completes

### Requirement: Add-on fleet summaries separate action from missing evidence
The Add-on Fleet UI SHALL expose separate counters and filters for managed deployments,
healthy/running, updating, needs attention, unavailable/stale, expected inactive, and
observed only. "Needs attention" SHALL count only `action_required` rows. Every
non-healthy row SHALL show its stable reason and evidence age, and catalog/staged
package counts SHALL remain separate from runtime fleet health.

#### Scenario: Summary does not count stale agents as runtime failures
- **GIVEN** four assignments on an agent that has been disconnected beyond the freshness window
- **WHEN** the fleet summary renders
- **THEN** the four rows SHALL contribute to unavailable/stale
- **AND** SHALL NOT contribute to needs attention unless an independent desired-state validation error is known

#### Scenario: Built-ins and dormant helpers use truthful categories
- **GIVEN** a healthy built-in runtime with no assignment and a ready dormant ephemeral helper
- **WHEN** the fleet summary renders
- **THEN** the built-in runtime SHALL contribute to observed only
- **AND** the helper SHALL contribute to expected inactive
- **AND** neither SHALL contribute to needs attention

#### Scenario: Real failure remains prominent
- **GIVEN** a connected agent with fresh evidence that a managed systemd add-on is inactive after its convergence deadline
- **WHEN** the fleet summary renders
- **THEN** the row SHALL contribute to needs attention
- **AND** selecting that counter SHALL reveal the row with its assigned version, observed version/state, failure reason, and evidence timestamp

#### Scenario: Counters filter to explainable rows
- **GIVEN** a fleet containing rows in multiple health categories
- **WHEN** an operator selects any summary counter
- **THEN** the table SHALL filter to exactly the rows counted by that category
- **AND** every displayed row SHALL expose the reason it belongs to that category

#### Scenario: Disabled history does not masquerade as current desired state
- **GIVEN** an agent has only disabled historical assignments for an add-on
- **AND** the agent still reports that add-on running
- **WHEN** the fleet matrix renders
- **THEN** the runtime SHALL be shown as observed-only or required-runtime state
- **AND** disabled assignment versions SHALL remain available only as audit detail
- **AND** the row SHALL NOT claim the disabled package is the current assignment

#### Scenario: Older approved version is not labeled newer
- **GIVEN** an agent reports version `0.3.0` in sync with desired state
- **AND** the highest approved package is version `0.2.0`
- **WHEN** the fleet matrix renders version status
- **THEN** it SHALL NOT label `0.2.0` as a newer approved version
- **AND** upgrade availability SHALL be determined by semantic version comparison

### Requirement: Fleet inventory groups add-ons by agent

The Add-on Fleet UI SHALL render each agent as one visually bounded inventory card
containing that agent's add-on rows. Agent identity and aggregate alert counts SHALL
appear once per card rather than being repeated on every add-on row. Filtering SHALL
preserve the agent grouping while limiting the rows inside each card.

#### Scenario: One agent reports multiple add-ons

- **GIVEN** one agent has three assigned or observed add-ons
- **WHEN** the fleet inventory renders
- **THEN** it SHALL render one agent card containing three add-on rows
- **AND** the agent name and UID SHALL appear in the card header rather than as a repeated table column
- **AND** each add-on SHALL retain expandable version, desired-state, runtime, evidence, and diagnostic detail

### Requirement: Schema-generated numeric controls preserve numeric domains

Configuration forms generated from add-on JSON Schema SHALL distinguish `number`
from `integer`. Decimal defaults SHALL be accepted by browser validation, and a
positive JSON Schema `multipleOf` SHALL be reflected as the input step when present.

#### Scenario: Anomaly schema contains decimal defaults

- **GIVEN** an approved anomaly add-on schema declares `cusum_slack` as `number` with default `0.5`
- **AND** another numeric field declares `multipleOf: 0.1`
- **WHEN** an operator reviews or assigns the package
- **THEN** the browser SHALL accept `0.5` without rounding or step validation failure
- **AND** the `multipleOf` field SHALL use `0.1` as its step
- **AND** fields declared as `integer` SHALL remain integral
