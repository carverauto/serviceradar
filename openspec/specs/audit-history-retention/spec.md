# audit-history-retention Specification

## Purpose

Bounded retention for the append-only tables behind Settings -> Audit -> History:
the 17 AshPaperTrail `<resource>_versions` tables in the History allow-list,
including `sweep_group_versions`, plus the `api_events` and `security_events`
event logs. Without this capability the History version tables and
`api_events` grow without a bound; `security_events` already prunes at 90
days, and this capability makes that window operator-configurable. Each
window is a Helm value or environment variable, per table.
`AuditVersionRetentionWorker` prunes the version tables in bounded batches.
`ApiEventsRetentionWorker` and
`SecurityEventsRetentionWorker` each delete every row past the cutoff in one
run. The four `remote_access_*_versions` tables are covered separately by
`RemoteAccessVersionRetentionWorker` and are out of scope here.

## Requirements

### Requirement: Every Audit-Relevant Table Has a Retention Window
The system SHALL prune rows older than a configurable retention window from
every table backing the Settings -> Audit -> History view (the 17
AshPaperTrail `<resource>_versions` tables, including `sweep_group_versions`)
plus `platform.api_events` and `platform.security_events`.

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

### Requirement: Version-Table Pruning Runs as Batched Deletes
`AuditVersionRetentionWorker` SHALL delete rows from each History version
table in bounded batches, matching the existing
`RemoteAccessVersionRetentionWorker` pattern, so a large backlog cannot hold
a long-running lock or exceed its query timeout.
`ApiEventsRetentionWorker` and `SecurityEventsRetentionWorker` SHALL delete
every row past the cutoff in one run, the same shape
`SecurityEventsRetentionWorker` already uses.

#### Scenario: A version table has more prunable rows than one batch size
- **WHEN** `AuditVersionRetentionWorker` runs against a version table with
  more expired rows than its configured batch size
- **THEN** it SHALL delete at most `batch_size` rows from that table in that
  run
- **AND** remaining expired rows SHALL be pruned on a subsequent scheduled
  run

#### Scenario: An event log has more expired rows than the version-table batch size
- **WHEN** `ApiEventsRetentionWorker` or `SecurityEventsRetentionWorker` runs
  and the event table has more expired rows than
  `AUDIT_VERSION_RETENTION_BATCH_SIZE`
- **THEN** that worker SHALL delete every row past the cutoff in that run
