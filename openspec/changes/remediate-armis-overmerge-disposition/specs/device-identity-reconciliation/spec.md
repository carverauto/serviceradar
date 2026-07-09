## ADDED Requirements

### Requirement: Armis Over-Merge Disposition Reconstructs Per-Hardware Devices
The system SHALL provide an operator-invoked, dry-run-default remediation step
that reconstructs the correct per-hardware devices collapsed onto an Armis
mega-device, reconstructing target grouping from the device's current universal
MAC identifiers rather than from `merge_audit` history (which does not record the
ingest-time collapse). Target grouping SHALL reuse the same universal-MAC
definition as the ingest-time distinct-MAC veto so un-merge is the provable
inverse of prevention.

#### Scenario: Mega-device with distinct universal MACs is split
- **GIVEN** a non-deleted Armis-keyed device owns two or more mutually-distinct
  universally-administered atomic MAC identifiers
- **WHEN** the disposition runs in execute mode
- **THEN** it SHALL materialize one device per distinct universal-MAC group
  (adopting a live device, restoring a tombstoned one, or creating a fresh one)
  with the deterministic UID a veto-gated ingest of that hardware would produce
- **AND** it SHALL move each group's `mac` identifier rows to its reconstructed
  device through an audited reassignment (never a silent last-writer-wins repoint)
- **AND** it SHALL write one merge audit row with reason `unmerge` per split to
  arm the per-pair re-collapse cooldown

#### Scenario: Disposition does not depend on merge audit history
- **GIVEN** an Armis over-merge that was produced at ingest resolution time and
  left no reversible `merge_audit` row
- **WHEN** the disposition plans the split
- **THEN** it SHALL derive the target devices from the device's current
  identifier rows
- **AND** it SHALL NOT require or rely on `unmerge_device`/`merge_audit`
  provenance to rescue the MAC identifiers

### Requirement: Reassign-Before-Delete For Orphaned Sole-Copy MAC Identifiers
The disposition SHALL move each orphaned sole-copy `mac` identifier row (whose
only copy points at an Armis over-merge ghost) to its reconstructed per-hardware
device through the audited, last-seen-updating reassignment action, so the
hardware identity is preserved and its TTL clock is reset before any garbage
collection could remove it. The `verified` flag SHALL be preserved on
reassignment so cardinality caps never retire a rescued row.

#### Scenario: Sole-copy MAC row is rescued onto its reconstructed device
- **GIVEN** a `mac` identifier row is the only copy of its value and currently
  points at a device tombstoned by the Armis over-merge ghost cleanup
- **WHEN** the disposition reassigns it to the reconstructed per-hardware device
- **THEN** the row's `device_id` SHALL become the reconstructed device
- **AND** its `last_seen` SHALL be updated so the identifier TTL GC cannot reach it
- **AND** the reassignment SHALL be recorded in the rollback manifest

### Requirement: Single Armis Identifier Owner After Split
When a mega-device is split, the disposition SHALL place the typed
`armis_device_id` identifier on at most one reconstructed device, so the split
does not create a new source identity conflict where the same typed
`armis_device_id` appears on multiple active devices.

#### Scenario: Split does not create a multiple-devices Armis conflict
- **GIVEN** a mega-device carrying one `armis_device_id` and several distinct
  universal MACs
- **WHEN** the disposition splits it into per-hardware devices
- **THEN** no more than one resulting active device SHALL carry that
  `armis_device_id` identifier
- **AND** the Armis northbound candidate query SHALL still resolve that
  `armis_device_id` to exactly one device

### Requirement: Unsplittable Armis Collapses Are Reported, Not Split
The disposition SHALL treat Armis collapses that have no universally-administered
MAC anchor (no MAC, or only locally-administered MACs) as out of scope for
MAC-based splitting: it SHALL report them with a reason and SHALL NOT split,
guess, or use `armis_device_id` or `source_device_id` alone as a split key.

#### Scenario: MAC-less Armis device is skipped with a reason
- **GIVEN** an Armis-collapsed device with no universally-administered MAC identifier
- **WHEN** the disposition runs
- **THEN** it SHALL report the device as skipped with an unsplittable reason
- **AND** it SHALL NOT create or repoint any device or identifier for it

### Requirement: Ghost-Cleanup GC Guards Removed Only After Disposition Completes
The system SHALL keep the maintenance guards that protect Armis over-merge ghost
tombstones and their sole-copy `mac` rows from garbage collection and retention
in place until a verification confirms no sole-copy `mac` rows remain on those
tombstones. Guard removal SHALL be a separate, explicitly-gated action.

#### Scenario: Guards are not removed while orphaned rows remain
- **GIVEN** sole-copy `mac` rows still point at devices tombstoned with the Armis
  over-merge ghost-cleanup reason
- **WHEN** guard removal is considered
- **THEN** the identifier-GC and device-retention guards SHALL remain in effect
- **AND** removal SHALL proceed only after a verification query returns zero such
  rows
