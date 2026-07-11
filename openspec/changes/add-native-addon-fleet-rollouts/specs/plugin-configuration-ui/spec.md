## ADDED Requirements

### Requirement: Native add-on update policy is visible and explicit
The native add-on assignment and profile UI SHALL show whether desired versions are
manually pinned or track the latest approved eligible package. Manual pin SHALL be the
default, and enabling tracking SHALL require an authorized operator to review and save
canary, batch, soak, timeout, failure-tolerance, release-channel, and capability-ceiling
settings.

#### Scenario: Existing profile shows a manual pin
- **GIVEN** an existing add-on profile pinned to version `0.2.22`
- **WHEN** an operator opens the profile
- **THEN** the UI SHALL show `manual_pin` and version `0.2.22`
- **AND** SHALL explain through state and controls that approving a newer package does not change this desired version

#### Scenario: Operator opts into latest-approved tracking
- **GIVEN** an authorized operator editing a manually pinned source
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

### Requirement: Add-on Fleet is grouped and paginated by agent
The Add-on Fleet UI SHALL present one compact expandable parent row per agent on the
current server-side page. The parent SHALL summarize identity, connectivity, total and
matching add-on counts, and highest-priority health. Its expanded content SHALL show
the matching per-add-on desired, observed, policy, runtime, freshness, and diagnostic
details without loading the complete fleet into the LiveView.

#### Scenario: Operator expands an agent
- **GIVEN** an agent on the current page with multiple add-ons
- **WHEN** the operator expands that agent
- **THEN** the UI SHALL reveal its matching add-on rows in the existing page payload
- **AND** SHALL NOT perform one database query per expanded agent
- **AND** collapsing or expanding the agent SHALL NOT resize unrelated parent rows unexpectedly

#### Scenario: Unfiltered expansion shows all associated add-ons
- **GIVEN** no row-level add-on or health filter is active
- **WHEN** an operator expands an agent
- **THEN** every fleet add-on record associated with that agent SHALL be visible
- **AND** the parent summary SHALL show the same total add-on count

#### Scenario: URL restores fleet navigation state
- **GIVEN** an operator has selected an agent search, add-on/category filters, sort, page, and page size
- **WHEN** the URL is copied, reloaded, or revisited
- **THEN** the UI SHALL restore those server-side query controls
- **AND** changing any filter SHALL reset navigation to the first page

#### Scenario: Summary counter is independent of page
- **GIVEN** actionable add-ons exist on several agent pages
- **WHEN** the operator views any one page
- **THEN** the needs-attention counter SHALL show the full filtered-fleet total
- **AND** selecting it SHALL reset to the first page and display only parent agents with matching actionable child rows

#### Scenario: Page controls remain bounded and responsive
- **GIVEN** more agents than fit on one page
- **WHEN** the fleet surface renders on desktop or mobile
- **THEN** the operator SHALL be able to choose only supported page sizes 25, 50, or 100 and navigate pages
- **AND** parent and child labels, status, and diagnostics SHALL not overlap or overflow their containers
