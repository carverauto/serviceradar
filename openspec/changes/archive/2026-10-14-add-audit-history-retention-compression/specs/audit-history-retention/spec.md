## ADDED Requirements

### Requirement: Every Audit-Relevant Table Has a Retention Window
The system SHALL prune rows older than a configurable retention window from
every table backing the Settings -> Audit -> History view (the 16
AshPaperTrail `<resource>_versions` tables) plus `platform.api_events` and
`platform.security_events`.

#### Scenario: A version row older than its table's retention window exists
- **WHEN** the retention worker covering that table's tier runs
- **THEN** rows in that table with `version_inserted_at` older than the
  table's configured retention window SHALL be deleted
- **AND** rows within the window SHALL NOT be deleted

#### Scenario: An `api_events` row older than its retention window exists
- **WHEN** `ApiEventsRetentionWorker` runs
- **THEN** rows with `occurred_at` older than the configured window SHALL be
  deleted
- **AND** rows within the window SHALL NOT be deleted

### Requirement: Retention Windows Are Operator-Configurable Without a Rebuild
Every retention window added or changed by this capability SHALL be settable
via a Helm value (and its corresponding environment variable for non-Helm
deployments), following the existing `observabilityRetention` /
`ansible.runDetailDays` configuration pattern, without requiring a code
change or rebuild to adjust.

#### Scenario: An operator sets a longer retention window via Helm
- **WHEN** an operator sets a table's retention-days Helm value above its
  default
- **THEN** the corresponding worker SHALL use that value as its cutoff on
  its next run
- **AND** no code change SHALL be required

#### Scenario: No override is set
- **WHEN** an operator does not set a table's retention-days value
- **THEN** the worker SHALL use the documented default for that table's tier

### Requirement: `security_events` Retention Stays Configurable and Unchanged By Default
`SecurityEventsRetentionWorker`'s retention window SHALL become settable via
an environment variable, defaulting to its current hardcoded value so that
existing deployments see no behavior change unless an operator sets the new
variable.

#### Scenario: No environment variable is set
- **WHEN** `SECURITY_EVENTS_RETENTION_DAYS` is unset
- **THEN** `SecurityEventsRetentionWorker` SHALL prune at the same 90-day
  window it uses today

### Requirement: Retention Pruning Runs as Batched Deletes, Not Unbounded Sweeps
Each retention worker SHALL delete rows in bounded batches rather than in a
single unbounded statement, matching the existing
`RemoteAccessVersionRetentionWorker` pattern, so a large backlog cannot hold
a long-running lock or exceed its query timeout.

#### Scenario: A table has more prunable rows than one batch size
- **WHEN** a retention worker runs against a table with more expired rows
  than its configured batch size
- **THEN** it SHALL delete at most `batch_size` rows in that run
- **AND** remaining expired rows SHALL be pruned on a subsequent scheduled
  run
