## ADDED Requirements

### Requirement: Armis Over-Merge Disposition Reconstructs Per-Hardware Devices
The system SHALL provide an operator-invoked, dry-run-default remediation step
that reconstructs the correct per-hardware devices collapsed onto an Armis
mega-device, reconstructing target grouping from the device's current universal
MAC identifiers rather than from `merge_audit` history (which does not record the
ingest-time collapse). Target grouping SHALL reuse the same universal-MAC
definition as the ingest-time distinct-MAC veto so un-merge is the provable
inverse of prevention. The first-party Armis polling agent ID SHALL be treated
as observer provenance rather than discovered-device identity, so it cannot
resolve before or bypass the disjoint-MAC veto.

#### Scenario: Mega-device with distinct universal MACs is split
- **GIVEN** a non-deleted Armis-keyed device owns two or more mutually-distinct
  universally-administered atomic MAC identifiers
- **AND** the operator has enabled the runtime execution gate after live-scoping
  signoff
- **AND** the device UID and its non-faker sync source ID are both explicitly
  allowlisted for live-device execution
- **WHEN** the disposition runs in execute mode
- **THEN** it SHALL retain or restore the source UID for the survivor group and
  create each additional group fresh at an absent, stable remediation UID
  derived from `{armis_device_id, MAC, partition}`
- **AND** it SHALL move each group's `mac` identifier rows to its reconstructed
  device through an audited reassignment (never a silent last-writer-wins repoint)
- **AND** future ingest convergence SHALL rely on the reassigned typed MAC, not
  on unsupported UID parity for historical updates with additional strong seeds
- **AND** it SHALL write one merge audit row with reason `unmerge` per split to
  arm the per-pair re-collapse cooldown

#### Scenario: Shared Armis poller identity cannot re-collapse hardware
- **GIVEN** production-shaped Armis updates from one polling agent that share an
  `armis_device_id` but carry disjoint universal MACs
- **WHEN** identity resolution processes those updates
- **THEN** the polling `agent_id` SHALL be excluded from endpoint lookup and
  identifier registration
- **AND** each disjoint MAC SHALL remain owned by a distinct device
- **AND** neither endpoint SHALL resolve onto the polling agent's own host

### Requirement: Armis Disposition Execution Is Fail-Closed
The `armis-unmerge` step SHALL remain excluded from the default remediation run.
An operator SHALL be able to explicitly invoke a bounded dry-run while execute
mode is disabled. Execute mode SHALL be rejected before a manifest is opened or
any mutation occurs unless release runtime configuration enables the live-scoping
signoff gate. Live-device execution SHALL additionally require explicit,
nonempty device-UID and sync-source-ID allowlists, and a candidate backed by a
known faker source SHALL remain ineligible even when its hostname is not
faker-shaped. Before each candidate mutation, the system SHALL lock and compare
the exact source device and identifier snapshot, require exactly one typed
`armis_device_id` consistent with optional metadata, revalidate canonical Armis
source metadata and the independent integration-ID evidence, require the
integration source's canonical partition to match the planned universal-MAC
partition and recheck it under the source row lock, reject any global
normalized/display MAC or typed Armis alternate owner, and require every split
target UID to be absent. Every planned universal MAC row SHALL have one
canonical nonblank partition and all such rows SHALL agree; execute SHALL NOT
synthesize a default partition. Execute SHALL require a writable, synced
write-ahead manifest with distinguishable preflight, prepared, and committed
records.
The exact ownership snapshot SHALL contain `{id,type,value,partition}`; volatile
timestamps and unrelated identifier metadata SHALL NOT invalidate a plan, while
the semantic `sync_service_id` and `integration_type` provenance keys SHALL be
recomputed under lock.

#### Scenario: Dry-run remains available before signoff
- **GIVEN** the runtime execution gate is disabled
- **WHEN** an operator explicitly requests an `armis-unmerge` dry-run
- **THEN** the system SHALL return the bounded candidate and split-plan report
- **AND** it SHALL NOT mutate devices or identifiers

#### Scenario: Execute is rejected before signoff
- **GIVEN** the runtime execution gate is disabled
- **WHEN** an operator explicitly requests `armis-unmerge` in execute mode
- **THEN** the orchestrator SHALL reject the request before opening a rollback
  manifest or invoking the mutating step

#### Scenario: Live scope requires device and source allowlists
- **GIVEN** the runtime execution gate is enabled
- **WHEN** live-device execution is requested with only a device UID allowlist
  or only a sync source ID allowlist
- **THEN** the command SHALL reject the incomplete live scope
- **AND** no live device SHALL be mutated

#### Scenario: Live source partition must match the identity partition
- **GIVEN** an otherwise eligible live candidate whose integration source has a
  missing, noncanonical, or different partition than its universal MAC rows
- **WHEN** the disposition plans or executes the candidate
- **THEN** it SHALL report the partition mismatch and SHALL NOT mutate the
  candidate

#### Scenario: Faker source remains ineligible
- **GIVEN** an allowlisted live device resolves to a sync source whose endpoint
  is the ServiceRadar faker
- **WHEN** the disposition evaluates execution eligibility
- **THEN** it SHALL exclude that device regardless of its hostname

#### Scenario: Stale or ambiguous candidate fails before mutation
- **GIVEN** a dry-run plan whose display MAC, deletion reason, Armis metadata,
  discovery source, integration evidence, identifier ownership, universal-MAC
  partition, or integration-source partition changes before its transaction
  acquires locks
- **OR** the candidate has zero or multiple typed Armis identifiers
- **OR** a deterministic target or alternate normalized MAC owner already exists
- **WHEN** execute revalidates the candidate
- **THEN** it SHALL reject the complete candidate before restoring, creating, or
  reassigning any row

#### Scenario: Timestamp-only churn does not stale a plan
- **GIVEN** an eligible plan whose identifier `last_seen` changes before locking
- **WHEN** execute compares the ownership snapshot
- **THEN** the timestamp-only change SHALL NOT reject the candidate

#### Scenario: Source-linked evidence is mandatory
- **GIVEN** a live candidate whose typed Armis row or integration-ID evidence
  lacks `integration_type = 'armis'` and the canonical `sync_service_id`
- **WHEN** the disposition evaluates it
- **THEN** it SHALL remain ineligible even if two unrelated integration IDs exist

#### Scenario: Owner absence checks exclude concurrent writers
- **GIVEN** ordinary ingest is inserting or updating an identifier or display MAC
- **WHEN** execute reaches its owner revalidation transaction
- **THEN** a DML-conflicting owner-table barrier SHALL serialize that writer
- **AND** the indexed canonical, legacy-token, and display-token checks SHALL see
  every owner committed before the barrier
- **AND** lock or statement timeout SHALL fail the candidate without mutation
- **AND** a timeout exception SHALL become an inspectable nonzero step failure,
  preserving the rollback-manifest location instead of escaping the run

#### Scenario: Manifest is durable before database commit
- **GIVEN** an eligible execute candidate
- **WHEN** the disposition applies it
- **THEN** it SHALL sync a write-ahead preflight before mutation
- **AND** it SHALL append the exact prepared action entries as one batch and sync
  once per candidate before database commit
- **AND** prepared entries SHALL include every generated `merge_audit.event_id`
- **AND** it SHALL sync a committed marker after commit
- **AND** any manifest failure SHALL stop execution and produce a nonzero failure
- **AND** it SHALL never truncate or overwrite an existing manifest path

### Requirement: Armis Disposition Reports Are Bounded And Actionable
The operator CLI SHALL expose validated per-run candidate and plan-sample
limits. It SHALL print the report for every explicitly selected step, including
steps omitted from the default run. If an execute report contains a nonzero
failure count or reports execution as blocked, the CLI SHALL print the complete
report and rollback-manifest location and then terminate unsuccessfully.

#### Scenario: Explicit dormant-step report is printed
- **WHEN** an operator selects only `armis-unmerge` in dry-run mode
- **THEN** the CLI SHALL print the `armis-unmerge` counts and sampled split plans
- **AND** the candidate and plan-sample limits SHALL be within validated bounds

#### Scenario: Partial execute failure is not reported as success
- **GIVEN** one or more planned splits fail during execute mode
- **WHEN** the step returns its report
- **THEN** the CLI SHALL print the report and rollback-manifest location
- **AND** it SHALL terminate unsuccessfully with the nonzero failure counters

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

### Requirement: Unmerge Audits Are Cooldown Evidence Only
An audit row whose reason is `unmerge` SHALL arm the symmetric re-collapse
cooldown but SHALL NOT be exposed by canonical `merged_to` or `merged_from`
lineage reads.

#### Scenario: Current split metrics stay separate from survivor history
- **GIVEN** a current split device has an `unmerge` audit pointing to its source
  survivor
- **WHEN** the survivor metric view expands canonical pre-merge UID history
- **THEN** it SHALL NOT include the current split UID
- **AND** ordinary and legacy null-reason merge rows SHALL remain in canonical
  lineage

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

#### Scenario: Missing or mixed MAC partitions are skipped with a reason
- **GIVEN** an otherwise eligible Armis candidate whose universal MAC rows
  include a nil, blank, or noncanonical partition
- **OR** those rows contain more than one partition
- **WHEN** the disposition plans or executes the candidate
- **THEN** it SHALL report `missing_partition` or `multiple_partitions`
- **AND** it SHALL NOT create or repoint any device or identifier for it

#### Scenario: A multi-class display MAC is ambiguous
- **GIVEN** an otherwise eligible Armis candidate whose display MAC normalizes
  to more than one planned universal-MAC class
- **WHEN** the disposition chooses the survivor
- **THEN** it SHALL report `ambiguous_display_mac`
- **AND** it SHALL NOT choose from unordered set iteration or mutate the candidate

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
