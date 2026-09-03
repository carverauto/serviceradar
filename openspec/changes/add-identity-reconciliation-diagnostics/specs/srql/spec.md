## ADDED Requirements

### Requirement: SRQL Merge Audit Entity
SRQL SHALL provide `in:merge_audit` as a queryable device-merge audit entity backed by `platform.merge_audit`. Parser aliases SHALL include `device_merges` and `merges`. Results SHALL expose `event_id`, `from_device_id`, `to_device_id`, `reason`, `confidence_score`, `source`, `created_at`, and a key-allowlisted projection of `details`. The `time:` predicate SHALL filter `created_at`, and the default sort SHALL be `created_at desc`. Rows whose `reason` is `unmerge` SHALL be excluded unless the caller passes `include_unmerge:true`. Every predicate SHALL be parameterized.

#### Scenario: Find what a device was merged into
- **GIVEN** `merge_audit` records a merge from `sr:aaa` to `sr:bbb` with reason `duplicate_mac`
- **WHEN** a client queries `in:merge_audit from_device_id:sr:aaa`
- **THEN** SRQL SHALL return that merge row
- **AND** the row SHALL include `to_device_id`, `reason`, `source`, and `created_at`

#### Scenario: Unmerge rows are hidden by default
- **GIVEN** an `unmerge` row and a `duplicate_mac` row both reference `sr:aaa`
- **WHEN** a client queries `in:merge_audit from_device_id:sr:aaa`
- **THEN** SRQL SHALL return only the `duplicate_mac` row
- **AND** `in:merge_audit from_device_id:sr:aaa include_unmerge:true` SHALL return both

#### Scenario: Details are key-allowlisted
- **GIVEN** a merge row whose `details` jsonb carries both allowlisted keys and an unrecognized key
- **WHEN** a client queries `in:merge_audit`
- **THEN** the projected `details` SHALL contain only allowlisted keys
- **AND** the unrecognized key SHALL be absent from the result

### Requirement: SRQL Merge Chain Resolution
SRQL SHALL resolve the complete canonical merge chain for a device through `in:merge_audit chain:<device_uid>`. The walk SHALL traverse both directions from the seed: forward through `from_device_id` to `to_device_id`, and backward through `to_device_id` to `from_device_id`. Each row SHALL project `depth` as the number of hops from the seed and `direction` as `merged_into` or `merged_from`. The walk SHALL terminate on already-visited device ids and SHALL enforce a configurable depth cap defaulting to 32. When the depth cap truncates the walk, the response SHALL set `truncated` to true.

#### Scenario: Multi-hop chain resolves to the survivor
- **GIVEN** `sr:aaa` merged into `sr:bbb`, and `sr:bbb` merged into `sr:ccc`
- **WHEN** a client queries `in:merge_audit chain:sr:aaa`
- **THEN** SRQL SHALL return both merge edges
- **AND** the `sr:aaa` to `sr:bbb` edge SHALL have `depth` 1 and `direction` `merged_into`
- **AND** the `sr:bbb` to `sr:ccc` edge SHALL have `depth` 2 and `direction` `merged_into`

#### Scenario: Chain resolves ancestors as well as descendants
- **GIVEN** `sr:aaa` merged into `sr:bbb`
- **WHEN** a client queries `in:merge_audit chain:sr:bbb`
- **THEN** SRQL SHALL return the edge with `direction` `merged_from`

#### Scenario: Oscillating merge pair terminates
- **GIVEN** `sr:aaa` and `sr:bbb` have merge rows in both directions recorded repeatedly
- **WHEN** a client queries `in:merge_audit chain:sr:aaa`
- **THEN** the walk SHALL terminate rather than recurse indefinitely
- **AND** each distinct device SHALL be visited at most once

#### Scenario: Depth cap is reported, not hidden
- **GIVEN** a merge chain longer than the configured depth cap
- **WHEN** a client queries `in:merge_audit chain:<seed>`
- **THEN** SRQL SHALL return the chain up to the cap
- **AND** the response SHALL indicate `truncated` is true

### Requirement: SRQL Device Revival Audit Entity
SRQL SHALL provide `in:device_revival_audit` as a queryable entity backed by `platform.device_revival_audit`. Parser aliases SHALL include `device_revivals` and `revivals`. Results SHALL expose `event_id`, `device_uid`, `previous_deleted_at`, `previous_deleted_by`, `previous_deleted_reason`, `revived_at`, and `revived_by_application`. The `time:` predicate SHALL filter `revived_at`, and the default sort SHALL be `revived_at desc`.

#### Scenario: Inspect revivals for a device
- **GIVEN** a device `sr:aaa` was soft-deleted with reason `phantom apipa address` and later revived
- **WHEN** a client queries `in:device_revival_audit device_uid:sr:aaa`
- **THEN** SRQL SHALL return the revival row
- **AND** the row SHALL include `previous_deleted_by`, `previous_deleted_reason`, and `revived_by_application`

#### Scenario: Recent revivals across the fleet
- **GIVEN** revival rows exist inside and outside the last 24 hours
- **WHEN** a client queries `in:revivals time:last_24h`
- **THEN** SRQL SHALL return only rows whose `revived_at` falls in the window

### Requirement: SRQL Device Identifiers Entity
SRQL SHALL provide `in:device_identifiers` as a queryable identifier-ownership entity backed by `platform.device_identifiers`. Parser aliases SHALL include `identifiers` and `device_identity`. Results SHALL expose `id`, `device_id`, `identifier_type`, `identifier_value`, `partition`, `confidence`, `source`, `first_seen`, `last_seen`, `verified`, a key-allowlisted projection of `metadata`, and the joined owner fields `owner_hostname`, `owner_ip`, `owner_partition`, `owner_deleted`, `owner_deleted_at`, `owner_deleted_by`, and `owner_deleted_reason`. The `time:` predicate SHALL filter `last_seen`, and the default sort SHALL be `last_seen desc`.

#### Scenario: Identifier ownership for a device
- **GIVEN** device `sr:aaa` owns a `mac` identifier and an `agent_id` identifier
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa`
- **THEN** SRQL SHALL return both identifier rows with type, value, partition, and confidence

#### Scenario: Value lookup without a type stays index-backed
- **GIVEN** a `mac` identifier with value `001122334455`
- **WHEN** a client queries `in:identifiers value:001122334455`
- **THEN** SRQL SHALL constrain `identifier_type` to the complete closed set of declared identifier types
- **AND** the set SHALL include every type `DeviceIdentifier` declares, so a lookup for any type finds its rows
- **AND** the plan SHALL be able to use the leading column of the unique identifier index
- **AND** SRQL SHALL NOT emit a predicate on `identifier_value` alone

#### Scenario: Tombstoned owner is visible
- **GIVEN** an identifier whose owning device has been soft-deleted
- **WHEN** a client queries `in:device_identifiers value:<value>`
- **THEN** the row SHALL report `owner_deleted` as true
- **AND** the row SHALL include the owner `deleted_at`, `deleted_by`, and `deleted_reason`

### Requirement: SRQL Identifier Currency Projection
SRQL SHALL project `matches_current_facts` on `in:device_identifiers`, computed by comparing the identifier value against the owning device's current facts for the corresponding identifier type. A `mac` identifier SHALL match when it equals the owner's current `mac` or appears among the owner's interface MACs. An `agent_id`, `hostname`, or `ip` identifier SHALL match when it equals the corresponding current device column. The projection SHALL distinguish an identifier that reflects current corroborated ownership from one that is only historical.

The projection SHALL be three-valued. It SHALL be null for an identifier type that has no corresponding current fact on the device, and SHALL NOT report such an identifier as false. External-system keys (`armis_device_id`, `netbox_device_id`, `integration_id`), `hardware_serial`, and `passive_fingerprint` have no comparable device column, and reporting them as false would assert that they are stale.

#### Scenario: Current MAC is corroborated
- **GIVEN** device `sr:aaa` has current `mac` `001122334455` and an identifier row with the same value
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa identifier_type:mac`
- **THEN** the row SHALL report `matches_current_facts` as true

#### Scenario: Historical MAC is not corroborated
- **GIVEN** device `sr:aaa` owns an identifier for a MAC it no longer reports on any current fact or interface
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa identifier_type:mac`
- **THEN** that row SHALL report `matches_current_facts` as false
- **AND** the row SHALL still be returned rather than filtered out

#### Scenario: An external-system key is not reported as stale
- **GIVEN** device `sr:aaa` owns an `armis_device_id` identifier
- **WHEN** a client queries `in:device_identifiers device_id:sr:aaa identifier_type:armis_device_id`
- **THEN** the row SHALL report `matches_current_facts` as null
- **AND** the row SHALL NOT report `matches_current_facts` as false

### Requirement: SRQL Identity Evidence Edge Entity
SRQL SHALL provide `in:identity_evidence_edges` as a derived entity returning the connected component of devices joined by shared `(identifier_type, identifier_value, partition)` tuples in `platform.device_identifiers`. Parser aliases SHALL include `identity_evidence` and `evidence_edges`. Each row SHALL represent one edge and SHALL project `device_a`, `device_b`, `identifier_type`, `identifier_value`, `partition_a`, `partition_b`, `confidence`, `depth`, `direct`, and `cross_partition`. `direct` SHALL be true when the edge is incident to the seed device. `cross_partition` SHALL be true when the two endpoint devices have different partitions. The walk SHALL terminate on already-visited device ids and SHALL enforce the same configurable depth cap as merge chain resolution.

#### Scenario: Direct evidence is distinguished from transitive connectivity
- **GIVEN** device A and device B share a MAC identifier, and device B and device C share a different MAC identifier, while A and C share nothing
- **WHEN** a client queries `in:identity_evidence_edges device:A`
- **THEN** SRQL SHALL return the A-B edge with `direct` true and `depth` 1
- **AND** SRQL SHALL return the B-C edge with `direct` false and `depth` 2
- **AND** SRQL SHALL NOT emit an A-C edge

#### Scenario: Cross-partition evidence is flagged
- **GIVEN** two devices in different partitions are joined by a shared identifier value
- **WHEN** a client queries `in:identity_evidence_edges device:<seed>`
- **THEN** the edge SHALL report `cross_partition` as true
- **AND** the edge SHALL include both `partition_a` and `partition_b`

#### Scenario: Unseeded evidence query is refused
- **WHEN** a client queries `in:identity_evidence_edges` with no `device` or component seed filter
- **THEN** SRQL SHALL return a typed invalid-request error
- **AND** SRQL SHALL NOT execute a self-join across the identifier table

### Requirement: SRQL Identity Reconciliation Runs Entity
SRQL SHALL provide `in:identity_reconciliation_runs` as a queryable entity backed by `platform.identity_reconciliation_runs`. Parser aliases SHALL include `reconciliation_runs` and `dire_runs`. Results SHALL expose `run_id`, `started_at`, `completed_at`, `duration_ms`, `status`, `error_summary`, `duplicate_identifier_count`, `duplicate_components`, `mergeable_components`, `blocked_components`, `blocked_devices`, `largest_blocked_component`, `merges`, `errors`, `max_merges_configured`, `merge_cap_reached`, `blocked_component_devices`, `trigger`, and `job_schedule_id`. The `time:` predicate SHALL filter `started_at`, and the default sort SHALL be `started_at desc`.

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

### Requirement: Identity Diagnostic Entities Are Permission Gated
Every parser alias for `merge_audit`, `device_revival_audit`, `device_identifiers`, `identity_reconciliation_runs`, and `identity_evidence_edges` SHALL be registered under the `devices.view` permission in the SRQL entity access map. No identity diagnostic alias SHALL rely on the unknown-entity passthrough.

#### Scenario: Every alias resolves to a permission
- **WHEN** each canonical name and alias for the five identity diagnostic entities is resolved through the entity access map
- **THEN** each SHALL resolve to `devices.view`
- **AND** none SHALL resolve to the unknown-entity passthrough

#### Scenario: Caller without devices.view is refused
- **GIVEN** a caller whose permission set does not include `devices.view`
- **WHEN** that caller submits `in:merge_audit` over HTTP or MCP
- **THEN** the request SHALL be rejected as forbidden
- **AND** no query SHALL be executed
