## ADDED Requirements

### Requirement: SRQL Identity Decisions Entity
SRQL SHALL provide `in:identity_decisions` as a read-only entity backed by `platform.identity_decisions`. Parser aliases SHALL include `identity_decision` and `dire_decisions`. Results SHALL expose `id`, `decision_kind`, `reason`, `device_uids`, `device_count`, `subject`, `source`, `evidence`, `occurrence_count`, `first_decided_at`, and `last_decided_at`, and SHALL NOT expose the internal `decision_key`. A `device:` filter SHALL match every decision whose device set names that device. The `time:` predicate SHALL filter `last_decided_at`, and the default sort SHALL be `last_decided_at desc`.

#### Scenario: Find the decisions that refused a merge for a device
- **GIVEN** the merge policy refused to merge devices A and B three times
- **WHEN** a client queries `in:identity_decisions device:A`
- **THEN** SRQL SHALL return one decision row naming A and B
- **AND** the row SHALL report its `decision_kind`, `reason` and an `occurrence_count` of three

### Requirement: SRQL De-duplication Tasks Entity
SRQL SHALL provide `in:deduplication_tasks` as a read-only entity backed by `platform.identity_deduplication_tasks`. Parser aliases SHALL include `deduplication_task`, `dedup_tasks` and `identity_deduplication_tasks`. Results SHALL expose `id`, `status`, `device_uids`, `device_count`, `category`, `last_decision_kind`, `last_reason`, `evidence`, `occurrence_count`, `opened_at`, `last_decided_at`, `resolved_at`, `resolved_by`, `merged_into`, and `resolution_note`, and SHALL NOT expose the internal `candidate_key`. A `device:` filter SHALL match every task whose device set names that device. The `time:` predicate SHALL filter `last_decided_at`, and the default sort SHALL be `last_decided_at desc`.

#### Scenario: List the open tasks for a device
- **GIVEN** a device named by one open task and one task an operator marked distinct
- **WHEN** a client queries `in:deduplication_tasks status:open device:<uid>`
- **THEN** SRQL SHALL return only the open task

#### Scenario: A resolved task records who resolved it
- **GIVEN** an operator marked a task's devices distinct with a note
- **WHEN** a client queries `in:deduplication_tasks status:distinct`
- **THEN** the row SHALL report `resolved_by`, `resolved_at` and `resolution_note`

## MODIFIED Requirements

### Requirement: Identity Diagnostic Entities Are Permission Gated
Every parser alias for `merge_audit`, `device_revival_audit`, `device_identifiers`, `identity_reconciliation_runs`, `identity_evidence_edges`, `identity_decisions`, and `deduplication_tasks` SHALL be registered under the `devices.view` permission in the SRQL entity access map. No identity diagnostic alias SHALL rely on the unknown-entity passthrough.

#### Scenario: Every alias resolves to a permission
- **WHEN** each canonical name and alias for the seven identity diagnostic entities is resolved through the entity access map
- **THEN** each SHALL resolve to `devices.view`
- **AND** none SHALL resolve to the unknown-entity passthrough

#### Scenario: Caller without devices.view is refused
- **GIVEN** a caller whose permission set does not include `devices.view`
- **WHEN** that caller submits `in:merge_audit` over HTTP or MCP
- **THEN** the request SHALL be rejected as forbidden
