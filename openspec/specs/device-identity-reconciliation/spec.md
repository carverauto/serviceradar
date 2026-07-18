# device-identity-reconciliation Specification

## Purpose
TBD - created by archiving change fix-identity-batch-lookup-partition. Update Purpose after archive.
## Requirements
### Requirement: Partition-Scoped Batch Identifier Lookup
The system MUST resolve strong identifiers in batch mode within the update's partition, and MUST NOT match identifiers across partitions.

#### Scenario: Same identifier in different partitions
- **WHEN** two device updates in the same batch share the same strong identifier value but have different partitions
- **THEN** each update resolves to the device ID that matches its own partition

#### Scenario: Empty partition defaults consistently
- **WHEN** a device update has an empty partition value
- **THEN** identifier resolution treats it as partition `default` for both single and batch lookup paths

### Requirement: CNPG-Authoritative Identity Canonicalization
The system SHALL treat CNPG (via `IdentityEngine` + `DeviceRegistry`) as the authoritative source of canonical device identity, and SHALL NOT rely on KV as the source of truth for identity reconciliation.

#### Scenario: Registry processes updates without KV
- **WHEN** the core registry processes a batch of device updates
- **THEN** canonical device IDs are resolved and persisted via CNPG-backed identity reconciliation
- **AND** the registry does not require KV to be available to complete identity reconciliation

### Requirement: KV Identity Lookups Are Cache-Only
The system MAY use KV as a cache/hydration layer for limited identity lookups (e.g., IP and partition:IP used during sweep processing), but MUST continue to resolve identities correctly when KV is unavailable.

#### Scenario: KV miss falls back to CNPG
- **WHEN** a canonical identity lookup misses in KV
- **THEN** the system falls back to CNPG-backed lookup paths
- **AND** MAY hydrate the KV cache from the CNPG result

### Requirement: Tenant-Scoped Sync Ingestion Queue
The system SHALL enqueue sync result chunks per tenant and coalesce bursts within a configurable window before ingestion to smooth database load while preserving per-tenant ordering.

#### Scenario: Burst of sync results
- **WHEN** multiple sync result chunks arrive for the same tenant within the coalescing window
- **THEN** core SHALL merge the chunks into a single ingestion batch for that tenant
- **AND** ingestion for the tenant SHALL proceed in arrival order after coalescing
- **AND** the number of concurrent tenant ingestion workers SHALL be bounded by configuration

### Requirement: Multi-Identifier Convergence
The system SHALL reconcile device updates that contain multiple strong identifiers to a single canonical device ID, even when those identifiers currently map to different devices, within the same partition.

#### Scenario: Conflicting MAC identifiers merge into one device
- **GIVEN** a device update in partition `default` containing MAC A and MAC B
- **AND** MAC A maps to device ID X while MAC B maps to device ID Y
- **WHEN** DIRE processes the update
- **THEN** DIRE SHALL select a canonical device ID
- **AND** all identifiers (MAC A and MAC B) SHALL be assigned to the canonical device
- **AND** a `merge_audit` entry SHALL record the merge from the non-canonical device to the canonical device

### Requirement: Interface MAC Registration
The system SHALL register MAC addresses discovered on a device's interfaces as identifiers for that device within the device's partition. The polling agent's identity MUST NOT be included in the identifier registration. Locally-administered MACs (IEEE bit 1 of first octet set) SHALL be registered with `medium` confidence. Globally-unique MACs SHALL be registered with `strong` confidence.

#### Scenario: Interface MACs prevent duplicate devices
- **GIVEN** a mapper or sweep update that includes a list of interface MAC addresses for a device
- **WHEN** DIRE registers identifiers for the device
- **THEN** each globally-unique interface MAC SHALL be inserted into `device_identifiers` with `strong` confidence
- **AND** each locally-administered interface MAC SHALL be inserted with `medium` confidence
- **AND** the polling agent's `agent_id` SHALL NOT be included in the identifier registration
- **AND** subsequent updates that include any strong-confidence MAC SHALL resolve to the same device ID

#### Scenario: Locally-administered interface MACs do not cause false merges
- **GIVEN** two physically distinct devices share a locally-administered MAC from virtual interfaces
- **WHEN** DIRE registers interface identifiers for both devices
- **THEN** both MACs SHALL be registered with `medium` confidence
- **AND** DIRE SHALL NOT merge the two devices based solely on the shared medium-confidence MAC

### Requirement: IP Alias Resolution
The system SHALL resolve IP-only device updates using confirmed IP aliases before generating a new device ID.

#### Scenario: Interface-discovered IP alias resolves a sweep host
- **GIVEN** a device `sr:<uuid>` has a confirmed IP alias `216.17.46.98` recorded from interface discovery
- **WHEN** a sweep result arrives with host IP `216.17.46.98` and no strong identifiers
- **THEN** DIRE SHALL resolve the update to the canonical device ID
- **AND** SHALL NOT create a new device record for the alias IP

#### Scenario: Strong-ID update conflicts with confirmed IP alias
- **GIVEN** a device update with a strong identifier resolves to device ID X
- **AND** the update IP is a confirmed alias for device ID Y (Y != X)
- **WHEN** DIRE processes the update
- **THEN** DIRE SHALL merge the alias device into the strong-ID canonical device

### Requirement: IP Alias Sightings and Promotion
The system SHALL track IP alias sightings for weak identifiers and only promote aliases once they meet a configurable confirmation threshold.

#### Scenario: Alias remains pending until confirmed
- **GIVEN** a mapper interface update reports IP `192.168.10.1` as an interface address for device `sr:<uuid>`
- **WHEN** the alias has been sighted fewer times than the confirmation threshold
- **THEN** the alias SHALL remain in a pending state and SHALL NOT be used for canonical resolution

#### Scenario: Alias becomes active after confirmation
- **GIVEN** an IP alias has been sighted at or above the confirmation threshold
- **WHEN** the alias is processed
- **THEN** the alias SHALL be marked confirmed and eligible for identity resolution

### Requirement: Scheduled Reconciliation Backfill
The system SHALL run a scheduled reconciliation job that merges existing duplicate devices sharing strong identifiers and logs summary statistics for each run.

#### Scenario: Scheduled reconciliation merges duplicates and logs results
- **GIVEN** two device IDs that share the same strong identifier within a partition
- **WHEN** the reconciliation job runs
- **THEN** the non-canonical device SHALL be merged into the canonical device
- **AND** the job SHALL emit logs summarizing the number of duplicates scanned and merges performed

### Requirement: Merge Preserves Inventory Associations
The system SHALL reassign inventory-linked records to the canonical device ID during a merge.

#### Scenario: Interface records move to canonical device
- **GIVEN** two device IDs that each have `discovered_interfaces` records
- **WHEN** DIRE merges the non-canonical device into the canonical device
- **THEN** all `discovered_interfaces` records SHALL reference the canonical device ID

### Requirement: Polling Agent Exclusion from Interface MAC Registration
The system SHALL NOT include the polling agent's `agent_id` when registering interface MAC addresses discovered via SNMP or other remote polling. The `agent_id` in interface discovery records identifies the agent that performed the poll, not the device that owns the interface, and MUST be excluded from identifier registration for the polled device.

#### Scenario: Agent polls remote device interfaces without false merge
- **GIVEN** agent-dusk (at `192.168.2.22`) SNMP-polls tonka01 (`192.168.10.1`)
- **AND** tonka01 has interface MAC `0e:ea:14:32:d2:78`
- **WHEN** the mapper registers interface identifiers for tonka01
- **THEN** the MAC SHALL be registered as an identifier for tonka01
- **AND** `agent-dusk` SHALL NOT be included in the identifier registration for tonka01
- **AND** the agent-dusk device and tonka01 SHALL remain separate devices

### Requirement: Mapper Device Creation for Unresolved IPs
The system SHALL create a device record through DIRE when the mapper discovers interfaces on a device IP that has no existing device in inventory. The device SHALL receive a proper `sr:` UUID via DIRE and SHALL have `mapper` added to its `discovery_sources`.

#### Scenario: Mapper creates device for SNMP-polled host with no existing record
- **GIVEN** agent-dusk SNMP-polls farm01 at `192.168.2.1`
- **AND** no device exists in `ocsf_devices` with IP `192.168.2.1`
- **WHEN** the mapper processes the interface results
- **THEN** DIRE SHALL generate a deterministic `sr:` UUID for farm01
- **AND** a device record SHALL be created with `ip: 192.168.2.1` and `discovery_sources: ["mapper"]`
- **AND** interface records SHALL be processed and linked to the new device

#### Scenario: Mapper does not duplicate existing device
- **GIVEN** tonka01 already exists in `ocsf_devices` at IP `192.168.10.1`
- **WHEN** the mapper processes interface results for `192.168.10.1`
- **THEN** the existing device SHALL be used
- **AND** no new device SHALL be created

### Requirement: Locally-Administered MAC Classification
The system SHALL classify MAC addresses as globally-unique or locally-administered using the IEEE standard (bit 1 of the first octet). Locally-administered MACs MUST be registered with `medium` confidence and SHALL NOT be used as the sole basis for merging two devices.

#### Scenario: Locally-administered MAC does not trigger merge
- **GIVEN** device A has locally-administered MAC `0EEA1432D278` registered as a medium-confidence identifier
- **AND** device B reports the same MAC from interface discovery
- **WHEN** DIRE processes the interface MAC registration
- **THEN** DIRE SHALL NOT merge device B into device A based solely on a medium-confidence identifier match

#### Scenario: Globally-unique MAC still triggers merge
- **GIVEN** device A has globally-unique MAC `001122334455` (bit 1 of first octet is clear) registered as a strong identifier
- **AND** device B reports the same MAC from interface discovery
- **WHEN** DIRE processes the identifier conflict
- **THEN** DIRE SHALL merge the devices since the MAC is strong-confidence

### Requirement: Device Unmerge
The system SHALL provide an administrative `unmerge_device` action that reverses an incorrect merge using the `merge_audit` trail: recreating the from-device, reassigning its original identifiers, and recording an `unmerge_audit` entry.

#### Scenario: Unmerge restores from-device
- **GIVEN** a device was merged into another with a recorded merge_audit entry
- **WHEN** an administrator invokes `unmerge_device` with the from_device_id
- **THEN** the from-device SHALL be recreated in `ocsf_devices`
- **AND** identifiers that originally belonged to the from-device SHALL be reassigned back
- **AND** an `unmerge_audit` entry SHALL be recorded

### Requirement: Immutable source endpoint identifiers for topology evidence
The system SHALL preserve mapper/source endpoint identifiers as immutable evidence attributes during topology ingestion and reconciliation.

#### Scenario: Reconciliation does not rewrite source endpoint IDs
- **GIVEN** a topology observation with `source_uid` and `target_uid` from mapper evidence
- **WHEN** the identity engine resolves canonical device IDs
- **THEN** canonical IDs SHALL be linked as reconciliation metadata
- **AND** original `source_uid` and `target_uid` values SHALL remain unchanged in evidence storage

### Requirement: Unresolved endpoints remain explicit
The system SHALL represent unresolved topology endpoints explicitly and SHALL NOT merge them via presentation-layer hostname/IP guessing.

#### Scenario: Unknown endpoint is tracked as unresolved
- **GIVEN** a topology observation target cannot be resolved to a canonical device
- **WHEN** ingestion processes the observation
- **THEN** an unresolved endpoint record SHALL be persisted with the original evidence identifiers
- **AND** the unresolved endpoint MAY be reconciled later when additional strong identifiers arrive

### Requirement: Filesystem-Backed Device Enrichment Rules
The system SHALL load device enrichment rules from a layered source model consisting of built-in defaults and optional filesystem overrides located at `/var/lib/serviceradar/rules/device-enrichment/*.yaml`.

#### Scenario: Startup with override rules mounted
- **WHEN** core starts and override rule files are present in `/var/lib/serviceradar/rules/device-enrichment/`
- **THEN** core SHALL load built-in rules first and filesystem rules second
- **AND** filesystem rules SHALL be eligible to override built-in rules by `rule_id`

#### Scenario: Startup without override rules mounted
- **WHEN** core starts and no filesystem rule files are present
- **THEN** core SHALL load built-in rules only
- **AND** enrichment behavior SHALL remain available

### Requirement: Rule Merge and Precedence
The system SHALL merge enrichment rules deterministically by source, `rule_id`, and `priority`.

#### Scenario: Filesystem override replaces built-in rule
- **GIVEN** a built-in rule and a filesystem rule with the same `rule_id`
- **WHEN** rules are merged
- **THEN** the filesystem rule SHALL replace the built-in definition

#### Scenario: Multiple matching rules evaluate deterministically
- **GIVEN** multiple enabled rules match the same device payload
- **WHEN** enrichment runs
- **THEN** the highest-priority rule SHALL win
- **AND** tie-breaking SHALL be deterministic by rule ordering metadata

### Requirement: Rule Validation and Safe Fallback
The system SHALL validate filesystem rules at load time and SHALL continue operating with built-in defaults when filesystem rules are invalid.

#### Scenario: Invalid filesystem rule file
- **WHEN** a filesystem YAML file fails schema validation
- **THEN** core SHALL log the validation error with file and rule context
- **AND** invalid rules SHALL be skipped
- **AND** built-in defaults SHALL remain active

#### Scenario: Rule directory unreadable
- **WHEN** the filesystem rules directory is missing or unreadable
- **THEN** core SHALL emit a startup warning
- **AND** enrichment SHALL continue using built-in rules only

### Requirement: Rule-Driven Classification Provenance
The system SHALL persist provenance for applied enrichment classifications.

#### Scenario: Classification produced by enrichment rule
- **WHEN** an enrichment rule assigns `vendor_name` and/or `type`
- **THEN** device metadata SHALL include `classification_source`, `classification_rule_id`, `classification_confidence`, and `classification_reason`

#### Scenario: No rule match
- **WHEN** no enrichment rule matches an incoming payload
- **THEN** the system SHALL preserve existing classification values when present
- **AND** SHALL fall back to default unknown semantics when classification is absent

### Requirement: Source-Authoritative Identifier Integrity
The system SHALL treat typed stable identifiers from source integrations as source-authoritative device identity and SHALL NOT silently reassign them to unrelated device rows because of weak IP evidence.

#### Scenario: Generic source-authoritative integration update collides with unrelated active IP owner
- **GIVEN** an integration sync update contains source-scoped `integration_id = A` and IP `I`
- **AND** active IP `I` is already owned by device `D2`
- **AND** `D2` does not already carry integration ID `A` or another allowed non-MAC strong identifier match for the incoming update
- **WHEN** identity reconciliation processes the update
- **THEN** the system SHALL NOT reassign integration ID `A` to `D2`
- **AND** it SHALL preserve the source-authoritative mapping for integration ID `A`
- **AND** it SHALL not use IP evidence alone to merge those devices

#### Scenario: Armis update collides with unrelated active IP owner
- **GIVEN** an Armis sync update contains `armis_device_id = A`, MAC `M1`, and IP `I`
- **AND** active IP `I` is already owned by device `D2`
- **AND** `D2` does not already carry Armis Device ID `A` or another allowed non-MAC strong identifier match for the incoming update
- **WHEN** identity reconciliation processes the update
- **THEN** the system SHALL NOT reassign Armis Device ID `A` to `D2`
- **AND** it SHALL preserve the source-authoritative mapping for Armis Device ID `A`
- **AND** it SHALL record a source identity conflict or retire the stale IP owner only when policy can prove the owner is safe to retire

#### Scenario: DHCP churn for same Armis device
- **GIVEN** an existing canonical device has Armis Device ID `A`
- **AND** a later Armis sync update for Armis Device ID `A` reports a new IP address
- **WHEN** identity reconciliation processes the update
- **THEN** the update SHALL resolve to the existing canonical device for `A`
- **AND** the new IP evidence SHALL NOT create or rebind a second canonical device for `A`

### Requirement: Strong Source Identity Wins Over Active-IP Recovery
Active-IP uniqueness recovery SHALL be limited to weak or policy-approved cases and SHALL NOT use IP collision recovery to move source-authoritative identifiers between unrelated devices.

#### Scenario: Active-IP retry would move typed source identifier
- **GIVEN** a bulk sync insert hits the active-IP unique constraint
- **AND** one of the incoming records has a typed source-authoritative identifier
- **AND** the existing active-IP owner does not match that typed identifier
- **WHEN** the retry path chooses how to recover
- **THEN** it SHALL NOT rewrite the incoming record's identifier rows to the existing active-IP owner
- **AND** it SHALL emit an identity conflict diagnostic that includes the incoming source identifier, incoming IP, existing device UID, and existing identifiers

#### Scenario: Weak IP-only update can still reuse existing row
- **GIVEN** an incoming update has no strong source identifier
- **AND** active IP `I` already belongs to an existing non-deleted device
- **WHEN** identity reconciliation processes the update
- **THEN** the system MAY reuse the existing active-IP row according to the existing weak identity policy

### Requirement: Source Identity Drift Detection
The system SHALL detect source identity drift where source identifiers, generic integration identifiers, and device metadata disagree.

#### Scenario: One device carries multiple Armis identifiers
- **GIVEN** an active device has more than one distinct `armis_device_id` identifier
- **WHEN** the identity drift audit runs
- **THEN** the system SHALL report the device as conflicted
- **AND** automated northbound actions SHALL NOT collapse those identifiers into one outbound device update until the conflict is resolved

#### Scenario: Metadata disagrees with typed identifier
- **GIVEN** a device metadata field `armis_device_id` differs from the device's typed `armis_device_id` identifier
- **WHEN** the identity drift audit runs
- **THEN** the system SHALL report the metadata/identifier disagreement
- **AND** repair tooling SHALL either update stale metadata to match the single typed identifier or leave an unresolved conflict when the correct identity is ambiguous

#### Scenario: Typed and generic source identifiers split
- **GIVEN** Armis Device ID `A` appears as a typed `armis_device_id` identifier on one device
- **AND** the same value appears as a generic `integration_id` identifier on another active device for the same Armis source
- **WHEN** the identity drift audit runs
- **THEN** the system SHALL report the split mapping
- **AND** identity reconciliation SHALL NOT treat both rows as valid candidates for the same source device

