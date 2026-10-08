## MODIFIED Requirements

### Requirement: Restore Soft-Deleted Devices
The system SHALL support restoring soft-deleted devices, and every restore, whatever path performs it, SHALL clear tombstone metadata, increment `identity_revision`, and leave a `device_revival_audit` row. A device soft-deleted because it was merged into another device SHALL NOT be restored by discovery.
A device soft-deleted with `deleted_reason` `source_retired` SHALL be restored only by the
corroborated return of its retired source identifier or by an operator, and a device
soft-deleted with `deleted_reason` `seed_released` only by an operator; no sweep, address-only
or MAC-only sighting SHALL restore either. A sweep SHALL restore a `stale_ephemeral` tombstone
that it matches, whatever the device's discovery sources, and SHALL restore a tombstone with
any other permitted reason only when the device has a discovery source other than the sweep.
No sweep write SHALL change the availability or last-seen time of a tombstone that the sweep
does not restore.

#### Scenario: Restore clears tombstone metadata
- **GIVEN** a device with `deleted_at` set
- **WHEN** an admin or operator restores the device
- **THEN** `deleted_at` SHALL be cleared
- **AND** `deleted_by` and `deleted_reason` SHALL be cleared
- **AND** `identity_revision` SHALL be incremented
- **AND** the device SHALL appear in default inventory reads

#### Scenario: Discovery restores a deleted device
- **GIVEN** a device with `deleted_at` set, a `deleted_reason` other than `merged`, `source_retired` or `seed_released`, and a discovery source other than the sweep
- **WHEN** a sweep, integration sync, or agent check-in matches the device identity
- **THEN** the device SHALL be restored automatically
- **AND** `identity_revision` SHALL be incremented
- **AND** availability/last_seen metadata SHALL be updated from the discovery result

#### Scenario: Discovery does not restore a merged-away device
- **GIVEN** a device soft-deleted with `deleted_reason` `merged`
- **WHEN** a sweep, integration sync, or agent check-in matches it
- **THEN** the match SHALL resolve to the device it was merged into
- **AND** the merged-away device SHALL remain deleted

#### Scenario: A sweep restores an expired sweep-only device
- **GIVEN** a device discovered only by sweeps was soft-deleted with `deleted_reason` `stale_ephemeral` while holding address `192.0.2.20`
- **AND** no live device holds `192.0.2.20`
- **WHEN** a sweep finds `192.0.2.20` answering
- **THEN** the device SHALL be restored
- **AND** `identity_revision` SHALL be incremented and a `device_revival_audit` row SHALL record the `stale_ephemeral` tombstone it cleared
- **AND** its availability and last-seen time SHALL be updated from the sweep result

#### Scenario: A sweep does not write to a tombstone it does not restore
- **GIVEN** a device discovered only by sweeps was soft-deleted by an operator while holding address `192.0.2.21`
- **AND** no live device holds `192.0.2.21`
- **WHEN** a sweep finds `192.0.2.21` answering
- **THEN** the device SHALL remain deleted
- **AND** its availability and last-seen time SHALL NOT change

#### Scenario: Evidence does not restore a source-retired device
- **GIVEN** a device soft-deleted with `deleted_reason` `source_retired` after its Armis device id 1001 was retired
- **WHEN** a sweep, an address-only sighting or a sighting matching only its MAC `00:00:5e:00:53:01` arrives
- **THEN** the device SHALL remain deleted

#### Scenario: A returning source id restores a source-retired device
- **GIVEN** a device soft-deleted with `deleted_reason` `source_retired` after its Armis device id 1001 was retired
- **WHEN** Armis reports id 1001 again with the archived MAC and hostname
- **THEN** the device SHALL be restored and SHALL hold Armis device id 1001
- **AND** `identity_revision` SHALL be incremented and a `device_revival_audit` row SHALL be written

## ADDED Requirements

### Requirement: Source-Retired Devices Are Hidden By Default
The system SHALL exclude devices marked `source_retired` from default inventory reads, from SRQL device queries that do not ask for retired devices, and from inventory counts. A read that asks for retired devices SHALL include them, and a device's detail view, opened by its uid, SHALL show a marked device together with the time its grace period ends.

#### Scenario: Default reads hide a source-retired device
- **GIVEN** a live device marked `source_retired`
- **WHEN** a default device list read or inventory count is executed
- **THEN** the device SHALL NOT be included

#### Scenario: Retired devices are included on demand
- **GIVEN** a live device marked `source_retired`
- **WHEN** a device list read asks for retired devices
- **THEN** the device SHALL be included and shown as `source_retired`

#### Scenario: A default SRQL query hides a source-retired device
- **GIVEN** a live device marked `source_retired`
- **WHEN** an SRQL `in:devices` query without a retired filter runs
- **THEN** the device SHALL NOT be returned

#### Scenario: The detail view shows a source-retired device
- **GIVEN** a live device marked `source_retired` 2 days ago, with a 7-day grace period
- **WHEN** an operator opens the device by its uid
- **THEN** the device SHALL be shown as `source_retired`
- **AND** the view SHALL show when the device will be deleted

### Requirement: Expiry Holds Source Identifiers Recorded Only In Metadata
The statement that soft-deletes expired ephemeral devices SHALL itself hold, and so never expire, a device whose metadata carries a non-empty agent id, Armis device id, NetBox device id or integration id, whether the value is a JSON string or a JSON number, even when the device has no identifier row and even when the in-memory evidence check does not read the value.

#### Scenario: A metadata-only source id holds the device in the delete
- **GIVEN** expiry is enabled
- **AND** a device unseen past the expiry window has no identifier row and carries Armis device id 1001 only in its metadata
- **WHEN** the soft delete for that device's batch runs, with the in-memory evidence check skipped
- **THEN** the device SHALL NOT be soft-deleted

#### Scenario: A numeric metadata value still holds the device
- **GIVEN** expiry is enabled
- **AND** a device unseen past the expiry window carries the NetBox device id 1001 in its metadata as a JSON number
- **WHEN** the cleanup runs
- **THEN** the device SHALL NOT be soft-deleted

### Requirement: Expiry Reports What It Counts
An ephemeral expiry pass SHALL judge its mass-expiry guard against the number of devices it would expire after both keep checks, and SHALL report, under distinct names, in its result, its log line and its telemetry: the stage-one candidates, the candidates kept by attribute or metadata evidence, the candidates kept by the exclusion query, the eligible devices, the devices expired, and the eligible devices the delete's re-check refused.
A candidate matched by the exclusion query SHALL be counted as kept by the exclusion query,
and any other kept candidate as kept by evidence. A refused pass SHALL report the eligible and
live counts and SHALL state that the override stays set until an operator clears it.

#### Scenario: Held candidates do not trip the guard
- **GIVEN** expiry is enabled with a maximum fraction of 0.5
- **AND** 60 of 100 live devices are stage-one candidates, of which 50 are kept by metadata evidence
- **WHEN** the cleanup runs without the override
- **THEN** the pass SHALL NOT be refused
- **AND** the 10 eligible devices SHALL be expired

#### Scenario: Each count is reported under its own name
- **GIVEN** a pass with 10 stage-one candidates, of which 3 are kept by evidence and 2 match the exclusion query
- **WHEN** the pass completes
- **THEN** it SHALL report 10 candidates, 3 kept by evidence, 2 kept by the exclusion query and 5 eligible
- **AND** the log line and telemetry SHALL carry the same names and values

#### Scenario: A refusal names the eligible count and the persistent override
- **GIVEN** a pass would expire more than the configured fraction of live devices after both keep checks
- **WHEN** the cleanup runs without the override
- **THEN** no device SHALL be expired
- **AND** the refusal SHALL report the eligible and live counts and state that the override stays set until cleared
