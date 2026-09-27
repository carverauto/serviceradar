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
The system SHALL resolve an address-only device update through a confirmed IP alias before generating a new device ID, and SHALL NOT merge devices because of a confirmed IP alias.
A confirmed alias is address evidence, subordinate to strong identity. When an update identified
by a strong identifier arrives at an address that is a confirmed alias of a different device, the
two devices stay separate: an alias holder that is itself identified has the conflicting alias
invalidated, recorded as an `alias_invalidated` identity decision, and an address-only holder is
left alone.

#### Scenario: Interface-discovered IP alias resolves a sweep host
- **GIVEN** a device `sr:<uuid>` has a confirmed IP alias `192.0.2.98` recorded from interface discovery
- **WHEN** a sweep result arrives with host IP `192.0.2.98` and no strong identifiers
- **THEN** DIRE SHALL resolve the update to the canonical device ID
- **AND** SHALL NOT create a new device record for the alias IP

#### Scenario: A strong-identified update at an identified holder's alias
- **GIVEN** a device update with a strong identifier resolves to device X
- **AND** the update IP is a confirmed alias for device Y, which holds a strong identifier of its own
- **WHEN** DIRE processes the update
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the alias state for that IP on device Y SHALL be invalidated
- **AND** an `alias_invalidated` identity decision SHALL name both devices and the address

#### Scenario: A strong-identified update at an address-only holder's alias
- **GIVEN** a device update with a strong identifier resolves to device X
- **AND** the update IP is a confirmed alias for device Y, which holds no strong identifier
- **WHEN** DIRE processes the update
- **THEN** devices X and Y SHALL NOT be merged

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
The system SHALL run a scheduled reconciliation job that merges existing duplicate devices sharing strong identifiers, logs summary statistics for each run, and persists a durable run record for each run.

#### Scenario: Scheduled reconciliation merges duplicates and logs results
- **GIVEN** two device IDs that share the same strong identifier within a partition
- **WHEN** the reconciliation job runs
- **THEN** the non-canonical device SHALL be merged into the canonical device
- **AND** the job SHALL emit logs summarizing the number of duplicates scanned and merges performed

#### Scenario: Run summary survives the run
- **WHEN** the reconciliation job completes
- **THEN** the job SHALL persist a run record containing the summary statistics
- **AND** the record SHALL remain queryable after the process that produced it has exited

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

### Requirement: Reconciliation Run Record
The system SHALL persist one durable record per scheduled reconciliation run. The record SHALL contain the run identifier, start and completion timestamps, duration, status, the count of duplicate identifier candidates, the duplicate, mergeable, and blocked component counts, the number of devices covered by blocked components, the size of the largest blocked component, the merges performed, the error count, the configured per-run merge cap, whether that cap was reached, the device membership of each blocked component, and the trigger that started the run.

#### Scenario: Completed run is recorded
- **WHEN** a reconciliation run completes without raising
- **THEN** a run record SHALL be written with status `completed`
- **AND** the record SHALL carry every summary counter the run computed

#### Scenario: Cap-reached is recorded, not inferred
- **GIVEN** a reconciliation run whose merges reach the configured per-run cap
- **WHEN** the run completes
- **THEN** the run record SHALL carry the configured cap
- **AND** the run record SHALL record that the cap was reached

#### Scenario: Largest blocked component is retained
- **GIVEN** a run classifies one or more ambiguous components as blocked
- **WHEN** the run completes
- **THEN** the run record SHALL carry the size of the largest blocked component
- **AND** the run record SHALL carry the device uids belonging to each blocked component

### Requirement: Failed Reconciliation Runs Are Recorded
The system SHALL persist a run record when a reconciliation run raises and is rescued. The record SHALL carry status `failed` and a summary of the error, together with whatever counters were established before the failure.

#### Scenario: Rescued run leaves evidence
- **GIVEN** a reconciliation run raises partway through
- **WHEN** the job rescues the exception
- **THEN** a run record SHALL be written with status `failed`
- **AND** the record SHALL include an error summary
- **AND** the absence of a run record SHALL NOT be the only signal that a run failed

### Requirement: Run Recording Never Fails Reconciliation
The system SHALL NOT allow a failure to write the reconciliation run record to fail, roll back, or abort the reconciliation run itself. A failed run-record write SHALL be logged and otherwise ignored.

#### Scenario: Audit write failure does not block merges
- **GIVEN** the reconciliation run record cannot be written
- **WHEN** a reconciliation run completes its merges
- **THEN** the merges SHALL remain committed
- **AND** the run SHALL return its normal result
- **AND** the write failure SHALL be logged

### Requirement: Reconciliation Run Retention
The system SHALL retain reconciliation run records for a configurable window, defaulting to 30 days, and SHALL prune older records as part of each run.

#### Scenario: Old run records are pruned
- **GIVEN** run records exist that are older than the configured retention window
- **WHEN** a subsequent reconciliation run completes
- **THEN** the records older than the window SHALL be deleted
- **AND** records inside the window SHALL be retained

### Requirement: Identity Reconciliation Diagnostics Are Available Without Database Access
The system SHALL make identity reconciliation diagnostics reachable through SRQL and MCP under normal RBAC, without requiring direct database credentials. This SHALL cover live and tombstoned devices, merge audit records, revival audit records, identifier ownership and its currency against present device facts, canonical merge chains, reconciliation run summaries, and the evidence edges of a component.

#### Scenario: Reconcile an inventory list without psql
- **GIVEN** an operator holding `devices.view` and an external inventory list
- **WHEN** the operator uses only SRQL or MCP
- **THEN** the operator SHALL be able to classify each entry as active, tombstoned, or absent from inventory
- **AND** the operator SHALL NOT require direct database credentials

#### Scenario: Explain an inventory count drop
- **GIVEN** devices disappeared from inventory following a reconciliation run
- **WHEN** an operator investigates through SRQL or MCP
- **THEN** the operator SHALL be able to trace each tombstoned device to its current survivor
- **AND** the operator SHALL be able to see the merge reason, source, timestamp, and supporting evidence
- **AND** the operator SHALL be able to see whether the run stopped at its configured work cap

### Requirement: Provider-Neutral Integration Identity Evidence
The system SHALL NOT admit or reject an integration `integration_id` based on the provider name. Bare numeric provider-native IDs SHALL NOT become `:integration_id` identifiers; source-scoped values and existing opaque identifiers SHALL resolve through the generic `:integration_id` path for any provider. An identifier's prefix need not match `integration_type`, since hypervisor updates carry provider-owned identifiers.

#### Scenario: Scoped provider ID resolves generically
- **GIVEN** a sync update with `integration_type: "armis"` and `integration_id: "armis:source-a:device:42001"`
- **WHEN** DIRE extracts strong identifiers
- **THEN** the update SHALL carry an `:integration_id` identifier with the scoped value
- **AND** the identifier SHALL be looked up and registered like any other provider's scoped ID

#### Scenario: Bare provider-native ID is rejected
- **GIVEN** a sync update with `integration_type: "armis"` and a bare numeric `integration_id` such as `"42001"`
- **WHEN** DIRE extracts strong identifiers
- **THEN** no `:integration_id` identifier SHALL be produced from the bare value
- **AND** resolution SHALL rely on the provider's typed identifier (`armis_device_id`) and other evidence

### Requirement: Persisted Identity Decision Log
The system SHALL persist every identity decision that blocks, declines or overrides a merge
as an identity decision record naming the decision kind, the reason, every device the
decision is about, the address it concerns (if any) and the evidence, in addition to any
telemetry. Decision kinds SHALL cover merge-policy refusals, merge-guard refusals,
source-authority conflicts, IP alias invalidations, active-IP conflicts and
source-authoritative overrides. A repeat of the same decision (same kind, reason, address and
device set) SHALL update its existing record's occurrence count, last decision time and
evidence instead of adding a record. Identity decision records SHALL be readable by any
viewer and writable only by the system.

#### Scenario: A refused merge is recorded
- **GIVEN** an update whose identifiers match two devices only through randomized MACs
- **WHEN** the merge policy refuses to merge them
- **THEN** an identity decision record of kind `policy_block` SHALL name both devices
- **AND** it SHALL carry the matched identifiers as evidence

#### Scenario: A merge guard refusal is recorded
- **GIVEN** two devices bound to different agents
- **WHEN** an automatic merge of the two is refused by the distinct-agent guard
- **THEN** an identity decision record of kind `guard_block` SHALL name both devices and the
  guard

#### Scenario: An alias invalidation is recorded
- **GIVEN** a confirmed IP alias held by a device whose identity conflicts with the device now
  seen at that address
- **WHEN** the alias is marked stale instead of merging the devices
- **THEN** an identity decision record of kind `alias_invalidated` SHALL name both devices and
  the address

#### Scenario: A repeated decision does not add records
- **GIVEN** an identity decision record for a refused merge
- **WHEN** the same merge is refused again
- **THEN** the existing record's occurrence count SHALL increase by one
- **AND** no second record SHALL be written

#### Scenario: Administrative merges are not decisions
- **WHEN** an administrator merges two devices
- **THEN** no identity decision record SHALL be written for that merge

### Requirement: Identity De-duplication Tasks
The system SHALL open a de-duplication task for every identity decision that blocks, declines
or overrides a merge between two or more devices, and SHALL keep exactly one task per candidate
device set for the set's whole life: a later decision about the same set SHALL update that task
and SHALL NOT open a second task or reopen a task an operator resolved or dismissed. An operator
SHALL be able to resolve an open task by merging its devices into one of them, by marking them
distinct, or by dismissing it, and the resolution, the resolving actor and the time SHALL be
recorded on the task. Marking devices distinct SHALL record a durable assertion for every pair,
and no automatic merge path SHALL merge an asserted pair. A decision about devices that are
already asserted distinct SHALL NOT open a task.

#### Scenario: A refused merge opens one task
- **GIVEN** two devices whose shared identifiers are only randomized MACs
- **WHEN** the merge policy refuses to merge them, twice
- **THEN** exactly one open de-duplication task names both devices
- **AND** its occurrence count is two

#### Scenario: Marking devices distinct stops automatic merges
- **GIVEN** an open task for two devices
- **WHEN** an operator marks them distinct
- **THEN** the task is recorded as distinct with the operator and time
- **AND** every automatic merge of the pair, including the scheduled duplicate backfill, is
  refused

#### Scenario: Merging from a task
- **GIVEN** an open task for three devices
- **WHEN** an operator merges them into one of the three
- **THEN** the other two are merged into the survivor through the administrative merge path
- **AND** the task is recorded as merged into that survivor

#### Scenario: A dismissed task stays dismissed
- **GIVEN** a task an operator dismissed
- **WHEN** the same merge is refused again
- **THEN** the task's occurrence count increases
- **AND** the task stays dismissed until an operator reopens it

#### Scenario: Only operators resolve tasks
- **WHEN** a viewer tries to merge, mark distinct or dismiss a task
- **THEN** the action is refused and no device changes

### Requirement: De-duplication Review Queue
The web UI SHALL provide a review queue at `/devices/deduplication` that lists de-duplication tasks by status, open tasks first by default, each with its device set, the kind and reason of the decision that opened it, its occurrence count and the time of its latest decision. Reviewing a task SHALL show its devices, including tombstoned ones, and the identity decisions about exactly that device set with their evidence. Any user with `devices.view` SHALL be able to read the queue; only a user allowed to resolve tasks SHALL be offered, and SHALL be able to perform, merge into a chosen survivor, mark distinct, dismiss and reopen. Every queue event SHALL re-check the user's permission, and a resolution SHALL re-read the task rather than trust the submitted form. A task resolved elsewhere SHALL leave the open queue of every session showing it without a reload. Resolution notifications SHALL be sent only after the resolving transaction commits, and a resolution that is refused or rolls back SHALL send none.

#### Scenario: An operator resolves a task from the queue
- **GIVEN** an open task for two devices
- **WHEN** an operator reviews it, selects one device to keep and merges
- **THEN** the other device is merged into the selected one
- **AND** the task is recorded as merged into it and leaves the open queue

#### Scenario: A viewer reads the queue but cannot resolve
- **GIVEN** an open task
- **WHEN** a viewer opens the queue and submits a merge, mark distinct or dismiss event directly
- **THEN** the task and the devices are listed
- **AND** each action is refused and the task stays open

#### Scenario: A resolution in another session updates the queue
- **GIVEN** an operator viewing the open queue
- **WHEN** another operator dismisses one of the listed tasks
- **THEN** the task leaves the first operator's open queue without a reload

#### Scenario: A rolled-back resolution sends no notification
- **GIVEN** an operator viewing the open queue
- **WHEN** another operator's resolution of a listed task is refused or its transaction rolls back
- **THEN** no resolution notification is sent
- **AND** the task stays in the first operator's open queue

### Requirement: Source-Authoritative Identifier Integrity
The system SHALL treat the typed source-authoritative identifiers, `armis_device_id` and `netbox_device_id`, as device identity and SHALL NOT silently reassign them to unrelated device rows because of weak IP evidence.
A generic `integration_id` is not source-authoritative. It never vetoes a match that other
evidence supports, and it governs identity only through the typed provider id it accompanies.

#### Scenario: NetBox update collides with unrelated active IP owner
- **GIVEN** a NetBox sync update contains `netbox_device_id = N` and IP `I`
- **AND** active IP `I` is already owned by device `D2`
- **AND** `D2` does not already carry NetBox device ID `N` or another allowed non-MAC strong identifier match for the incoming update
- **WHEN** identity reconciliation processes the update
- **THEN** the system SHALL NOT reassign NetBox device ID `N` to `D2`
- **AND** it SHALL preserve the source-authoritative mapping for NetBox device ID `N`
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

### Requirement: Address Is Evidence, Not Identity
The system SHALL NOT use an IP address, or a confirmed IP alias, as a device's identity: an address change SHALL NOT create a device record for a device that holds a strong identifier, and address evidence SHALL NOT merge two device records.
An address-only sighting attaches to the device that currently holds that address. DHCP moves
addresses between devices, so "same address" never implies "same device". Only a record that is
not yet a device may adopt an anchorless provisional seed (a sweep-created row) that holds its
address; an existing device takes the address by the newer-observation rule instead.

#### Scenario: A known device changes address
- **GIVEN** a device identified by a strong identifier at address A
- **WHEN** an update carrying the same strong identifier arrives from address B
- **THEN** the update SHALL resolve to the existing device
- **AND** no new device record SHALL be created

#### Scenario: An address moves to a different device
- **GIVEN** device X held address A and has since moved to another address
- **AND** device Y, holding a different strong identifier, is now assigned address A
- **WHEN** updates for both devices are processed
- **THEN** devices X and Y SHALL remain separate records

#### Scenario: An address-only sighting attaches without merging
- **GIVEN** a live device currently holds address A
- **WHEN** a sighting with address A and no strong identifier arrives
- **THEN** the sighting SHALL attach to that device
- **AND** no device SHALL be created or merged because of it

#### Scenario: An existing device does not adopt a provisional seed
- **GIVEN** an anchorless provisional device, created by a sweep, holds address A
- **AND** a device identified by a strong identifier already exists at another address
- **WHEN** an update for the existing device reports address A
- **THEN** the existing device SHALL take address A, as the newer observation
- **AND** the provisional device SHALL release address A and stay live
- **AND** the existing device SHALL NOT adopt the provisional record
- **AND** an `ip_conflict` identity decision SHALL be recorded

### Requirement: Source-Authoritative Identifiers Govern Identity
The system SHALL treat a source-authoritative identifier (the Armis device id and the NetBox device id) as governing a record's identity: two records holding different values of the same source-authoritative identifier type in one scope SHALL NOT be merged, whatever MAC or address evidence they share.
An `integration_id` is not source-authoritative on its own, because providers do not mint it
stably per device; it never vetoes a match and governs identity only through the typed
provider id it accompanies.
When such a record reports a MAC or address that a different device holds, the
source-authoritative identifier decides the record's identity, and the MAC or address is
evidence only.

#### Scenario: Different Armis ids with a shared MAC stay separate
- **GIVEN** device X holds Armis device id 1 and device Y holds Armis device id 2
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: Different NetBox device ids with a shared MAC stay separate
- **GIVEN** device X holds NetBox device id 1 and device Y holds NetBox device id 2
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: A changed integration id re-attaches through the device's MAC
- **GIVEN** a device holds integration id G1 and a globally-unique MAC M
- **WHEN** the same source reports integration id G2 with MAC M
- **THEN** the update SHALL resolve to that device

### Requirement: One Live Owner Per Strong Identifier
The system SHALL ensure that each strong identifier, within its partition, is held by at most one live device record.

#### Scenario: A strong identifier is claimed by a second record
- **GIVEN** a live device holds a strong identifier
- **WHEN** another record reports the same identifier
- **THEN** that record SHALL resolve to, or converge with, the device holding it
- **AND** the identifier SHALL NOT be held by two live records

### Requirement: Interface Identifiers Belong To Their Device
The system SHALL register the MAC addresses of a device's own interfaces as dependent identifiers of that device: each SHALL resolve to the device, and none SHALL create a device record of its own.

#### Scenario: A router with many interfaces stays one device
- **GIVEN** a router reports interfaces with MACs M1, M2 and M3
- **WHEN** DIRE registers the interface identifiers
- **THEN** M1, M2 and M3 SHALL all resolve to the router
- **AND** no device record SHALL be created for any single interface

### Requirement: Randomized MACs Are Evidence Only
The system SHALL NOT merge two device records on locally-administered (randomized) MAC addresses, alone or together with other evidence-class identifiers, and SHALL NOT seed a device uid from one.
An update whose only strong identifier is a MAC is seeded from its first universally
administered MAC, even when a randomized MAC is listed first. An update with no universally
administered MAC is address-only and is named by its address. The one exception is an update
with neither a strong identifier nor an address: it falls back to its MAC, because a random uid
would mint a new record on every sighting. Resolver lookup still matches a randomized MAC that is
already registered to a device, so existing registrations (a hardware sibling's randomized
interface, a virtual machine) keep resolving; registering and merging stay governed by this
requirement.
A device identified only by evidence-class identifiers is ephemeral. Expiring it is covered by
#4603, and such expiry SHALL NOT remove a device holding a hardware or source-authoritative
identifier.

#### Scenario: Two devices share a randomized MAC
- **GIVEN** two device records that share only a locally-administered MAC
- **WHEN** DIRE processes updates for both
- **THEN** the records SHALL NOT be merged

#### Scenario: A randomized MAC seen at two addresses
- **WHEN** sightings carrying the same locally-administered MAC and no other strong identifier
  arrive from addresses A and B
- **THEN** they SHALL resolve to two address-only records named by their addresses
- **AND** no device uid SHALL be seeded from the randomized MAC

#### Scenario: A MAC-only update lists a randomized MAC first
- **GIVEN** an update whose MACs are a locally-administered MAC followed by a universally
  administered MAC, with no other strong identifier
- **WHEN** DIRE names the record
- **THEN** its uid SHALL be seeded from the universally administered MAC

### Requirement: Duplicates Converge And Stay Converged
The system SHALL converge device records that share a hardware or source-authoritative identifier into one canonical record, and SHALL NOT let an automatic path bring a merged-away record back.
A merged-away device id resolves to its survivor for as long as anything may still present it,
including after its tombstone row is purged. Only an administrative unmerge brings it back, and
the unmerge restores exactly the identifiers the record held when it was merged. A device
deleted for any other reason resolves to itself and is never redirected through an old merge
row.

#### Scenario: A merged-away id is presented again
- **GIVEN** device F was merged into device T
- **WHEN** an ingest, sweep, gateway or agent path later presents device F's id
- **THEN** the id SHALL resolve to device T
- **AND** device F SHALL NOT become live again

#### Scenario: A purged merged-away id is presented again
- **GIVEN** device F was merged into device T and F's tombstone was purged after retention
- **WHEN** a source presents device F's id
- **THEN** the id SHALL resolve to device T
- **AND** no device record with F's id SHALL be created

#### Scenario: Unmerge restores exactly the source's identifiers
- **GIVEN** device F held identifiers S when it was merged into device T
- **WHEN** an administrator unmerges F
- **THEN** exactly the identifiers in S that T still holds SHALL move back to F
- **AND** T SHALL keep every identifier it held that is not in S

#### Scenario: An unrelated deletion does not follow an old merge
- **GIVEN** device F was merged into T and later unmerged
- **WHEN** device F is deleted for a reason other than a merge
- **THEN** F's id SHALL resolve to F itself

### Requirement: Identity Decisions Are Never Silent
The system SHALL record every identity decision that blocks a merge, declines one, or overrides conflicting evidence where an operator can review it, and SHALL NOT make such a decision observable only through logs or telemetry.
The operator workflow for reviewing and acting on these records is #4604.

#### Scenario: A source-authoritative override is recorded
- **GIVEN** a record with a source-authoritative identifier reports a MAC another device holds
- **WHEN** DIRE keeps the records separate
- **THEN** an identity decision record SHALL be written naming both devices and the evidence

### Requirement: Hostname Agreement Is Not Identity
The system SHALL NOT merge two existing devices because their hostnames agree, and SHALL NOT adopt an address holder on hostname agreement when either side holds a source-authoritative identifier.
Hostname agreement at an address may still let a record that is not yet a device adopt the
address holder, when neither side holds a source-authoritative identifier, their hardware
serials and partitions are compatible, and no third device claims either identity. When the
hostnames agree and adoption is refused, the record is written as its own device and the pair is
recorded as a `policy_block` identity decision with reason `hostname_agreement_not_identity`,
which opens a de-duplication task.

#### Scenario: Two existing devices with the same hostname stay separate
- **GIVEN** two live devices whose hostnames agree
- **WHEN** an update for one of them reports the address the other holds
- **THEN** the devices SHALL NOT be merged
- **AND** a `policy_block` identity decision SHALL name both devices

#### Scenario: A source-authoritative holder is not adopted on hostname agreement
- **GIVEN** a device holding an Armis device id at address A
- **WHEN** a NetBox record with the same hostname and address A arrives
- **THEN** the NetBox record SHALL be written as its own device
- **AND** a `policy_block` identity decision SHALL name both devices

### Requirement: Merge Stability and Oscillation Protection
The system SHALL prevent merge oscillation: weak or medium evidence (including confirmed IP aliases) MUST NOT merge two devices that hold distinct strong identities (e.g. different `agent_id` identifiers); a device pair that has merged in either direction within a configurable cooldown window MUST NOT be re-merged automatically (the attempt is blocked, audited, and alerted); merged-away device IDs MUST NOT be recreated by deterministic UID generation or identifier registration (canonical-alias lookup precedes creation).

#### Scenario: IP alias cannot override agent identity
- **GIVEN** device A holds `agent_id` identifier `agent-host02` and device B holds `agent_id` identifier `agent-host01`
- **AND** an IP of device A is recorded as a confirmed alias of device B
- **WHEN** an update for device A is processed
- **THEN** devices A and B are NOT merged
- **AND** the conflicting alias state is flagged for invalidation

#### Scenario: Merge cooldown breaks ping-pong loops
- **GIVEN** devices X and Y were merged within the cooldown window
- **WHEN** a subsequent update would merge them again (in either direction)
- **THEN** the merge is blocked and an oscillation alert is emitted with the pair history

#### Scenario: Tombstoned device is not resurrected
- **GIVEN** device F was merged into device T
- **WHEN** a later update or agent hello produces device F's deterministic UID or one of its former identifiers
- **THEN** resolution returns canonical device T
- **AND** no new device record with F's ID is created

