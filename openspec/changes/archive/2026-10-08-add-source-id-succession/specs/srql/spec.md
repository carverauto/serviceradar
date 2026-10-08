## MODIFIED Requirements

### Requirement: SRQL Identity Reconciliation Runs Entity
SRQL SHALL provide `in:identity_reconciliation_runs` as a queryable entity backed by `platform.identity_reconciliation_runs`. Parser aliases SHALL include `reconciliation_runs` and `dire_runs`. Results SHALL expose `run_id`, `started_at`, `completed_at`, `duration_ms`, `status`, `error_summary`, `duplicate_identifier_count`, `duplicate_components`, `mergeable_components`, `blocked_components`, `blocked_devices`, `largest_blocked_component`, `merges`, `errors`, `max_merges_configured`, `merge_cap_reached`, `blocked_component_devices`, `blocked_merges`, `blocked_unchanged`, `succession_merges`, `succession_reviews`, `successions_skipped`, `successions_deferred`, `max_successions_configured`, `trigger`, and `job_schedule_id`. The `time:` predicate SHALL filter `started_at`, and the default sort SHALL be `started_at desc`.
The blocked and succession counters SHALL accept numeric comparisons as filters, and
`blocked_merges`, `blocked_unchanged`, `succession_merges` and `succession_reviews` SHALL be
sortable.

#### Scenario: Detect a run that stopped at its work cap
- **GIVEN** a reconciliation run performed merges equal to its configured cap
- **WHEN** a client queries `in:identity_reconciliation_runs time:last_24h`
- **THEN** the run row SHALL report `merge_cap_reached` as true
- **AND** the row SHALL include `max_merges_configured` and the number of `merges` performed

#### Scenario: Failed runs are queryable
- **GIVEN** a reconciliation run raised and was rescued
- **WHEN** a client queries `in:reconciliation_runs status:failed`
- **THEN** SRQL SHALL return the run row with `status` `failed`
- **AND** the row SHALL include `error_summary`

#### Scenario: Blocked component membership is available
- **GIVEN** a run classified an ambiguous component of five devices as blocked
- **WHEN** a client queries `in:identity_reconciliation_runs run_id:<id>`
- **THEN** the row SHALL report `blocked_components` and `largest_blocked_component`
- **AND** `blocked_component_devices` SHALL list the device uids of each blocked component

#### Scenario: Blocked and succession counts are queryable
- **GIVEN** a run skipped three blocked components as unchanged, recorded two merges a guard
  refused, and merged one succession pair
- **WHEN** a client queries `in:dire_runs blocked_unchanged:>0`
- **THEN** SRQL SHALL return the run row with `blocked_unchanged` 3 and `blocked_merges` 2
- **AND** the row SHALL report `succession_merges` 1 apart from its `errors`
