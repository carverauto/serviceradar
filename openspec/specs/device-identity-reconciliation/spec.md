# device-identity-reconciliation Specification

## Purpose
Reconcile observed network device identifiers and evidence across sources, partitions, and lifecycles into authoritative canonical identities while preventing false merges and split records.

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
- **AND** the alias state for that IP on device Y SHALL be left unchanged

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
The system SHALL persist one durable record per scheduled reconciliation run. The record SHALL contain the run identifier, start and completion timestamps, duration, status, the count of duplicate identifier candidates, the duplicate, mergeable, and blocked component counts, the number of devices covered by blocked components, the size of the largest blocked component, the merges performed, the merges a merge guard refused, the blocked components and pairs skipped because their evidence was unchanged, the error count, the configured per-run merge cap, whether that cap was reached, the source succession merges performed, the succession candidates sent to review, skipped, and left for a later run, the configured per-run succession cap, the device membership of each blocked component, and the trigger that started the run.
A merge a merge guard refuses SHALL be counted as a blocked merge and SHALL NOT be counted as an error.

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

#### Scenario: A blocked merge is not an error
- **GIVEN** a run whose only failed merges were refused by the source-authority guard
- **WHEN** the run completes
- **THEN** the run record SHALL count those merges as blocked merges
- **AND** its error count SHALL be zero

#### Scenario: Succession counts are recorded
- **GIVEN** a run whose succession pass merges a corroborated pair
- **WHEN** the run completes
- **THEN** the run record SHALL count the succession merge apart from the duplicate merges
- **AND** the run record SHALL carry the configured per-run succession cap

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
address; an existing device takes the address by the newer-observation rule instead. A record
with archived identifier rows is anchored by them. When an
existing device takes the only address of an anchorless provisional seed -- one with no
identifier rows, current or archived, discovered only by sweeps and holding no other address -- the seed SHALL be
soft-deleted with `deleted_reason` `seed_released` in the same transaction, so a released seed
never stays live without an address.

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
- **GIVEN** an anchorless provisional device, created by a sweep, holds address A and nothing else
- **AND** a device identified by a strong identifier already exists at another address
- **WHEN** an update for the existing device reports address A
- **THEN** the existing device SHALL take address A, as the newer observation
- **AND** the existing device SHALL NOT adopt the provisional record
- **AND** the provisional device SHALL release address A and be soft-deleted with `deleted_reason` `seed_released` in the same transaction
- **AND** an `ip_conflict` identity decision SHALL be recorded

#### Scenario: A provisional seed with more than an address stays live
- **GIVEN** a provisional device holds address A and an identifier row
- **WHEN** an identified device takes address A
- **THEN** the provisional device SHALL release address A and stay live
- **AND** an `ip_conflict` identity decision SHALL be recorded

### Requirement: Source-Authoritative Identifiers Govern Identity
The system SHALL treat a current source-authoritative identifier (the Armis device id and the NetBox device id) as governing a record's identity: two records holding different current values of the same source-authoritative identifier type in one scope SHALL NOT be merged, whatever MAC or address evidence they share.
A value is current until it is retired by sustained absence from its source (requirement
"Source Identifiers Retire On Sustained Absence"). A retired value still bars a match at
ingest: an update carrying one value SHALL NOT be attached, through MAC or address evidence, to
a record that holds or held a different value of the same type in that scope. A retired value
SHALL give way only to the reconciler's corroborated succession (requirement "Corroborated
Source Identifier Succession"). Every other automatic merge path SHALL treat a retired value
exactly as it treats a current one.
An `integration_id` is not source-authoritative on its own, because providers do not mint it
stably per device; it never vetoes a match and governs identity only through the typed
provider id it accompanies.
When such a record reports a MAC or address that a different device holds, the
source-authoritative identifier decides the record's identity, and the MAC or address is
evidence only.

#### Scenario: Different Armis ids with a shared MAC stay separate
- **GIVEN** device X holds current Armis device id 1001 and device Y holds current Armis device id 2002
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: Different NetBox device ids with a shared MAC stay separate
- **GIVEN** device X holds current NetBox device id 1001 and device Y holds current NetBox device id 2002
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: A changed integration id re-attaches through the device's MAC
- **GIVEN** a device holds integration id G1 and a globally-unique MAC M
- **WHEN** the same source reports integration id G2 with MAC M
- **THEN** the update SHALL resolve to that device

#### Scenario: A new source id for a known MAC gets its own record at ingest
- **GIVEN** device X held Armis device id 1001, now retired, and holds MAC `00:00:5e:00:53:01`
- **WHEN** Armis reports device id 2002 with MAC `00:00:5e:00:53:01`
- **THEN** the update SHALL NOT be attached to device X
- **AND** a new record SHALL be created for Armis device id 2002
- **AND** a `source_override` identity decision SHALL name both records

#### Scenario: A retired id still blocks an uncorroborated automatic merge
- **GIVEN** device X holds only the retired Armis device id 1001 and device Y holds the current Armis device id 2002
- **AND** both hold MAC `00:00:5e:00:53:01` and nothing else corroborates them
- **WHEN** the scheduled duplicate backfill runs
- **THEN** devices X and Y SHALL NOT be merged

#### Scenario: A retired id gives way to corroborated succession
- **GIVEN** device X holds only the retired Armis device id 1001 and device Y holds the current Armis device id 2002
- **AND** both hold MAC `00:00:5e:00:53:01` and the hostname `host01.example.com`, and the pairing is one-to-one
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL converge into one record holding Armis device id 2002

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
A sweep seed is named by its address, so it SHALL NOT be created under the ID its address
derives when that ID redirects to a survivor; it SHALL take another ID.

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

#### Scenario: A sweep does not re-create a purged merged-away seed
- **GIVEN** a sweep seeded device F at address `192.0.2.30`, F was merged into device T, and F's tombstone was purged after retention
- **AND** no device holds `192.0.2.30`
- **WHEN** a sweep finds `192.0.2.30` answering
- **THEN** the sweep SHALL seed a new device whose ID is not F's
- **AND** F's ID SHALL still resolve to device T

### Requirement: Source Identifiers Retire On Sustained Absence
The system SHALL retire a source-authoritative identifier that its source has stopped reporting: when the identifier was absent from at least N consecutive exact, activated collections of the source instance that owns its scope, all under one collection query, and was last reported at least T ago, the system SHALL move its identifier row to the identifier archive, with its provenance, in one transaction, and SHALL record a `source_id_retired` identity decision naming the device, the identifier and the collections that proved the absence.
N and T SHALL be operator settings, defaulting to 3 collections and 24 hours. Only exact,
activated collections SHALL count, whether as presence or as absence. Presence in one SHALL
reset the count, and a change of collection query SHALL restart it. An identifier type whose
source produces no exact collections, or an identifier whose scope cannot be tied to one source
instance, SHALL NOT be retired by absence. Retirement SHALL run after a collection activates and
never during ingest. A retirement pass that would affect more than a configured fraction of the
source instance's live records SHALL be refused, and the refusal recorded, unless an operator
overrides it for that pass. A source-authoritative identifier SHALL leave the live identifier
table only by retirement, merge or unmerge, and never by identifier garbage collection or a
cardinality cap.

#### Scenario: One absence does not retire an id
- **GIVEN** device X holds Armis device id 1001
- **WHEN** an exact collection activates without id 1001
- **THEN** device X SHALL still hold Armis device id 1001 in the live identifier table

#### Scenario: N absences within T do not retire an id
- **GIVEN** Armis device id 1001 was last reported 6 hours ago
- **WHEN** a third consecutive exact collection activates without it
- **THEN** id 1001 SHALL NOT be retired

#### Scenario: Sustained absence retires an id
- **GIVEN** Armis device id 1001 was absent from 3 consecutive exact, activated collections under one query
- **AND** it was last reported more than 24 hours ago
- **WHEN** the retirement pass runs after the third collection activates
- **THEN** its identifier row SHALL be in the identifier archive and not in the live identifier table
- **AND** a `source_id_retired` identity decision SHALL name the device, the identifier and the three collections

#### Scenario: A presence resets the count
- **GIVEN** Armis device id 1001 was absent from 2 consecutive exact collections
- **WHEN** the next exact collection reports it
- **THEN** its absence count SHALL return to zero

#### Scenario: A collection that is not exact counts neither way
- **GIVEN** Armis device id 1001 was absent from 2 consecutive exact collections
- **WHEN** a collection whose accounting is not exact activates without it
- **THEN** its absence count SHALL stay at 2

#### Scenario: A changed query restarts the count
- **GIVEN** Armis device id 1001 was absent from 2 consecutive exact collections under one query
- **WHEN** an exact collection under a different query activates without it
- **THEN** its absence count SHALL be 1

#### Scenario: A source without exact collections never retires
- **GIVEN** a device holds NetBox device id 1001 and NetBox produces no exact collections
- **WHEN** NetBox stops reporting it
- **THEN** the identifier SHALL NOT be retired by absence

#### Scenario: A mass retirement is refused
- **GIVEN** a retirement pass would retire more than the configured fraction of the source instance's live records
- **WHEN** the pass runs without an operator override
- **THEN** no identifier SHALL be retired
- **AND** the refusal SHALL be logged at error level with the counts and emitted as telemetry

#### Scenario: Identifier garbage collection does not remove a source id
- **GIVEN** a device holds Armis device id 1001, unseen past the identifier TTL
- **WHEN** identifier garbage collection or a cardinality cap runs
- **THEN** Armis device id 1001 SHALL remain in the live identifier table unless it was retired

### Requirement: Corroborated Source Identifier Succession
The scheduled reconciliation SHALL converge a record whose source-authoritative identifiers of a type are all retired (the predecessor) with the record holding a current identifier of that type in the same scope (the successor) when, and only when, all of the following hold: both report a universally administered, unicast MAC that is not all-zero or broadcast and that links the predecessor to no other record holding a current identifier of that type; their source observations agree on the source first-seen time, or on the normalized hostname when the source first saw the successor no earlier than it last saw the predecessor; the pairing is one-to-one in both directions; and no distinct assertion or merge cooldown forbids the pair.
The record created first SHALL survive and SHALL take the current identifier. Source-owned
metadata SHALL come from the successor, facts carrying provenance SHALL merge per key by newest
provenance, and the survivor SHALL take the successor's address. The merge SHALL use reason
`source_succession`, SHALL pass through the merge engine's guards, and SHALL write a merge
audit row carrying the shared MAC, the corroborating field, the retired and current
identifiers and the collections that proved the retirement. An administrative unmerge of a
succession SHALL restore both records and SHALL record a distinct assertion for the pair.
Succession SHALL NOT run at ingest. A shared MAC alone SHALL NOT converge two records. Hostname
agreement only corroborates, a hostname held by more than one current record of the source
SHALL NOT corroborate, and a hostname SHALL NOT corroborate when either time is missing. Where
the evidence is weaker, the system SHALL record a `succession_review` identity decision, which
opens a de-duplication task, instead of merging: an equal hostname and first-seen time without a
shared MAC, a shared MAC without agreement on either field, a shared MAC and hostname whose
source times fail the guard, a MAC shared with another current record, or a pairing that is not
one-to-one.

#### Scenario: MAC and hostname converge a re-identified asset
- **GIVEN** device X, created first, holds only the retired Armis device id 1001
- **AND** device Y holds the current Armis device id 2002
- **AND** both report MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, and no other record shares either
- **AND** Armis first saw id 2002 after it last saw id 1001
- **WHEN** the scheduled reconciliation runs
- **THEN** device Y SHALL be merged into device X with reason `source_succession`
- **AND** device X SHALL hold Armis device id 2002
- **AND** a merge audit row SHALL carry the shared MAC, the hostname, both ids and the collections that retired 1001

#### Scenario: MAC and first-seen time converge a re-identified asset
- **GIVEN** device X holds only the retired Armis device id 1001 and device Y holds the current Armis device id 2002
- **AND** both report MAC `00:00:5e:00:53:01`, their hostnames differ, and Armis reports the same first-seen time for both
- **WHEN** the scheduled reconciliation runs
- **THEN** the two records SHALL converge into the one created first

#### Scenario: A shared MAC alone does not converge
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** they share MAC `00:00:5e:00:53:01`, and their hostnames and first-seen times differ
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `mac_only` SHALL open a de-duplication task naming both

#### Scenario: Hostname and first-seen time without a shared MAC go to review
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** they share no universally administered MAC, and agree on hostname and first-seen time
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `corroborated_without_mac` SHALL open a de-duplication task naming both

#### Scenario: Cloned machines sharing a MAC and a hostname do not converge
- **GIVEN** devices X and Y run copies of one image, and Armis reports both with MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, X under id 1001 and Y under id 2002
- **AND** Armis stops reporting id 1001, which retires
- **AND** their first-seen times differ, and Armis first saw id 2002 before it last saw id 1001
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `overlapping_hostname` SHALL open a de-duplication task naming both

#### Scenario: A hostname without source times does not corroborate
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** they share MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, and their first-seen times differ
- **AND** the archived observation of device X carries no last-seen time
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged
- **AND** a `succession_review` identity decision with reason `overlapping_hostname` SHALL open a de-duplication task naming both

#### Scenario: A MAC shared by cloned machines does not converge
- **GIVEN** device X holds only a retired Armis device id
- **AND** devices Y and Z each hold a current Armis device id
- **AND** all three report MAC `00:00:5e:00:53:01`
- **WHEN** the scheduled reconciliation runs
- **THEN** device X SHALL NOT be merged into either
- **AND** a `succession_review` identity decision with reason `shared_mac` SHALL open a de-duplication task

#### Scenario: A pairing that is not one-to-one goes to review
- **GIVEN** devices W and X each hold only a retired Armis device id, and device Y holds a current one
- **AND** both W and X satisfy the MAC and corroboration rules with Y
- **WHEN** the scheduled reconciliation runs
- **THEN** no record SHALL be merged
- **AND** a `succession_review` identity decision with reason `not_one_to_one` SHALL open a de-duplication task naming all three

#### Scenario: A randomized MAC never corroborates succession
- **GIVEN** device X holds only a retired Armis device id and device Y holds a current one
- **AND** the only MAC they share is locally administered
- **WHEN** the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged by succession

#### Scenario: Succession waits for retirement
- **GIVEN** device X holds Armis device id 1001, absent from one exact collection, and device Y holds Armis device id 2002
- **AND** they share MAC `00:00:5e:00:53:01` and hostname `host01.example.com`
- **WHEN** ingest or the scheduled reconciliation runs
- **THEN** devices X and Y SHALL NOT be merged

#### Scenario: An unmerged succession stays apart
- **GIVEN** device Y was merged into device X by succession
- **WHEN** an administrator unmerges device Y
- **THEN** both records SHALL be restored with the identifiers each held before the merge
- **AND** a distinct assertion SHALL be recorded for the pair
- **AND** no later scheduled run SHALL merge them again

### Requirement: Retired Source Identifiers Are Reserved
The system SHALL keep resolving a retired source-authoritative identifier through the identifier archive. When a source reports a retired identifier again, the system SHALL return it to the record that held it when it was retired, or to that record's merge survivor, only when exactly one such record qualifies: the record is live or a tombstone that was not merged away, holds no unretired identifier of that type in the identifier's scope, whether or not the source still reports it, shares a universally administered unicast MAC with the update (its own, its MAC identifiers, its interface MACs, or the MAC the source last reported for the identifier before it retired), and agrees with the update on the source first-seen time, or on the hostname (the one the source last reported or the record's own) when the update's first-seen time is no earlier than the identifier's archived last-seen time. An identifier archived without its source times SHALL be compared on the record's first-seen time, for equality only. Otherwise the system SHALL write the update as a new record, unless the usual resolution matches a record with no history of that type, and never to a record that held the identifier, and SHALL record a `source_id_reissued` identity decision naming both records, which opens a de-duplication task.
Returning an identifier SHALL resolve the update to that record and, in one transaction, SHALL
move its newest archive row back to the live identifier table, SHALL clear a `source_retired`
mark, SHALL restore a tombstone through the audited restore path, and SHALL record a
`source_id_reactivated` identity decision. When a read or the return fails, the system SHALL
withhold the updates carrying the identifier until the next sync run. Returning an identifier
SHALL NOT merge two live records.

#### Scenario: A retired id returns to its holder
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01` and hostname `host01.example.com`
- **AND** device X holds no current Armis device id
- **WHEN** Armis reports id 1001 again with MAC `00:00:5e:00:53:01`, hostname `host01.example.com` and the first-seen time it reported before
- **THEN** device X SHALL hold Armis device id 1001 in the live identifier table
- **AND** a `source_id_reactivated` identity decision SHALL be recorded

#### Scenario: A retired id reported for a different asset
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01`
- **WHEN** Armis reports id 1001 with MAC `00:00:5e:00:53:02` and a different hostname and first-seen time
- **THEN** a new record SHALL be created for the update
- **AND** device X SHALL NOT receive Armis device id 1001
- **AND** a `source_id_reissued` identity decision SHALL open a de-duplication task naming both records

#### Scenario: A retired id whose holder now holds a current id
- **GIVEN** device X held Armis device id 1001, retired, and now holds Armis device id 2002 in the live identifier table after a succession
- **WHEN** Armis reports id 1001 again
- **THEN** device X SHALL NOT receive Armis device id 1001
- **AND** a new record SHALL be created and a `source_id_reissued` identity decision SHALL name both records

#### Scenario: A retired id returns to a source_retired tombstone
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01`, and was soft-deleted with `deleted_reason` `source_retired`
- **WHEN** Armis reports id 1001 again with MAC `00:00:5e:00:53:01` and the first-seen time it reported before
- **THEN** device X SHALL be restored and SHALL hold Armis device id 1001 in the live identifier table
- **AND** the restore SHALL be recorded as a device revival

#### Scenario: A shared hostname from before the id was last seen
- **GIVEN** device X held Armis device id 1001, retired, with MAC `00:00:5e:00:53:01` and hostname `host01.example.com`, last seen by Armis at time T
- **WHEN** Armis reports id 1001 with MAC `00:00:5e:00:53:01`, hostname `host01.example.com` and a first-seen time earlier than T that differs from the one it reported before
- **THEN** device X SHALL NOT receive Armis device id 1001
- **AND** a new record SHALL be created and a `source_id_reissued` identity decision SHALL name both records

### Requirement: Retired Records Without A Successor
When a retirement leaves a live record holding only retired source-authoritative identifiers -- no agent identifier, no current source-authoritative identifier of another type, no identity-bearing observation within T, and not created by an operator -- the system SHALL mark it `source_retired` in the same transaction, and SHALL soft-delete it with `deleted_reason` `source_retired` once it has been marked for a grace period, releasing its address in the same transaction.
The grace period SHALL be an operator setting defaulting to 7 days. A marked record SHALL remain
a succession and reactivation candidate. A marked record named by an open de-duplication task
SHALL NOT be deleted while the task is open. A sweep, address-only or MAC-only sighting SHALL NOT
clear the mark, extend the grace period or restore the tombstone. The grace deletion pass SHALL
be bounded by the same mass guard as retirement. A record that an operator restores SHALL NOT be
marked again until another of its source-authoritative identifiers is retired. When a marked
record comes to hold an agent identifier or a source-authoritative identifier, by reactivation,
by a succession merge into it or by any ingest, the transaction that registers the identifier
SHALL clear the mark.

#### Scenario: A retired-only record is marked at once
- **GIVEN** device X holds only Armis device id 1001 and no other strong identifier from a current source
- **WHEN** id 1001 is retired
- **THEN** device X SHALL be marked `source_retired` in the same transaction

#### Scenario: A record with a current agent is not marked
- **GIVEN** device X holds Armis device id 1001 and an agent identifier that checked in an hour ago
- **WHEN** id 1001 is retired
- **THEN** device X SHALL NOT be marked `source_retired`

#### Scenario: The grace period ends in a soft delete
- **GIVEN** device X was marked `source_retired` 7 days ago and no open de-duplication task names it
- **WHEN** the device cleanup pass runs
- **THEN** device X SHALL be soft-deleted with `deleted_reason` `source_retired`
- **AND** device X SHALL no longer hold an address

#### Scenario: A pending review holds the deletion
- **GIVEN** device X was marked `source_retired` 7 days ago and an open de-duplication task names it
- **WHEN** the device cleanup pass runs
- **THEN** device X SHALL NOT be deleted

#### Scenario: A sweep does not keep a retired record alive
- **GIVEN** device X is marked `source_retired` and holds address `192.0.2.10`
- **WHEN** a sweep finds `192.0.2.10` answering, every hour until the grace period ends
- **THEN** device X SHALL still be soft-deleted when its grace period ends

#### Scenario: A new identifier clears the mark
- **GIVEN** device X is marked `source_retired`
- **WHEN** an ingest registers agent identifier `agent-01` on device X
- **THEN** device X SHALL NOT be marked `source_retired`
- **AND** the device cleanup pass SHALL NOT delete device X when the grace period ends

#### Scenario: A succession merge clears the survivor's mark
- **GIVEN** device X is marked `source_retired` after its Armis device id 1001 was retired
- **AND** device Y, created after X, holds the current Armis device id 2002 and passes the succession conditions with X
- **WHEN** the succession pass merges Y into X
- **THEN** device X SHALL hold Armis device id 2002
- **AND** device X SHALL NOT be marked `source_retired`

### Requirement: Retired Holders Do Not Keep An Address
A record holding a current source-authoritative identifier SHALL take an address from a holder that is marked `source_retired`, or whose source-authoritative identifiers are all retired, whatever their observation times. Between two identified records, the newer-observation rule SHALL compare the time of each record's last identity-bearing observation, which a sweep, an ARP or census sighting, or an address-only sighting SHALL NOT advance.
An identity-bearing observation carries a strong identifier as the device's own report: a source
sync carrying a current source-authoritative identifier, an agent check-in, or a discovery poll
of the device itself. A holder with no recorded identity-bearing observation SHALL be treated as
older than any record that has one.

#### Scenario: A retired holder yields the address
- **GIVEN** device X holds only the retired Armis device id 1001 and address `192.0.2.10`
- **AND** a sweep refreshed device X a minute ago
- **WHEN** an Armis update for the current id 2002 reports address `192.0.2.10`
- **THEN** the record holding id 2002 SHALL take address `192.0.2.10`
- **AND** device X SHALL no longer hold it

#### Scenario: A sweep refresh does not make a holder newer
- **GIVEN** device X's last identity-bearing observation is two days old and a sweep refreshed it a minute ago
- **AND** device Y's last identity-bearing observation is an hour old
- **WHEN** an update for device Y reports the address device X holds
- **THEN** device Y SHALL take the address

### Requirement: Blocked Components Are Not Retried Unchanged
The scheduled reconciliation SHALL record an evidence fingerprint for every component it blocks and for every pair a merge guard refuses on evidence -- covering the device set and the evidence that joined it, each device's live and archived identifiers, whether each device is deleted, its agent, identity state and identity source, the MACs of its interfaces, the distinct assertions covering the set, the surviving device where the guard's outcome depends on the direction of the merge, and the version of the reconciliation rules -- and SHALL skip, without re-attempting or re-recording it, a blocked component or pair whose fingerprint is unchanged since it was last blocked.
A change to any input of the fingerprint SHALL cause the component or pair to be evaluated again
on the next run. A blocked component or pair SHALL also be evaluated again once a bounded recheck
window, one day by default, has passed since it was last evaluated. A merge refused by the merge
cooldown SHALL NOT be skipped, because the cooldown depends on time rather than on evidence. A
skipped component SHALL be counted in the run record as blocked and unchanged, and a skipped pair
as a blocked merge that is blocked and unchanged.

#### Scenario: An unchanged blocked pair is skipped
- **GIVEN** a run blocked devices X and Y on a source-authority conflict
- **WHEN** the next run finds the same devices with the same identifiers
- **THEN** the merge SHALL NOT be attempted again
- **AND** the identity decision's occurrence count SHALL NOT increase
- **AND** the run record SHALL count the pair as a blocked merge that is blocked and unchanged
- **AND** its error count SHALL be zero

#### Scenario: An unchanged blocked component is skipped
- **GIVEN** a run blocked an ambiguous component of devices X, Y and Z
- **WHEN** the next run finds the same component with the same evidence
- **THEN** the component's identity decision SHALL NOT be recorded again
- **AND** the run record SHALL count the component as blocked and unchanged

#### Scenario: A blocked pair is re-checked after the recheck window
- **GIVEN** a run blocked devices X and Y on a source-authority conflict
- **WHEN** a run starts after the recheck window has passed with the same evidence
- **THEN** the merge SHALL be attempted again
- **AND** the identity decision's occurrence count SHALL increase by one

#### Scenario: A retirement re-opens a blocked component
- **GIVEN** a run blocked devices X and Y because X held Armis device id 1001
- **WHEN** id 1001 is retired and the next run starts
- **THEN** the component SHALL be evaluated again under the succession rules

#### Scenario: New reconciliation rules re-check every blocked component
- **GIVEN** blocked components recorded under one version of the reconciliation rules
- **WHEN** a release changes the rules and the next run starts
- **THEN** every blocked component SHALL be evaluated again once

### Requirement: IP Alias Rows Belong To One Device
The system SHALL keep an IP alias row per device: every device seen at an address SHALL have its own row of the address, filed under the device's partition, and only that device's sightings SHALL count toward confirming it.
Where several devices hold a confirmed alias of one address, a source sync, an agent check-in or
a mapper poll that resolves a device at the address SHALL handle every other holder by the rules
of requirement "IP Alias Resolution", and every lookup that resolves the address to one confirmed
holder SHALL take the most recently seen holder, then the one with the most sightings, then the
lowest device id. A merge of two devices that both hold a row of one address SHALL NOT fail on
it: the merged device's row SHALL be marked `replaced` by the survivor's, and a confirmation it
carried SHALL confirm the survivor's row when that row is pending or stale.

#### Scenario: A device seen at another device's alias gets its own row
- **GIVEN** device X holds a confirmed IP alias of `192.0.2.20`
- **WHEN** device Y is sighted at `192.0.2.20`
- **THEN** DIRE SHALL record the sighting on a pending alias row of `192.0.2.20` for device Y
- **AND** device X's row SHALL be left unchanged

#### Scenario: Sightings confirm only the sighted device's row
- **GIVEN** device X holds a pending IP alias of `192.0.2.21`
- **WHEN** device Y is sighted at `192.0.2.21` as often as the confirmation threshold
- **THEN** device Y's alias of `192.0.2.21` SHALL be confirmed
- **AND** device X's alias SHALL remain pending with its own sighting count

#### Scenario: Every identified holder of an address is handled
- **GIVEN** identified devices X and Y each hold a confirmed IP alias of `192.0.2.22`
- **WHEN** a source sync resolves device Z, identified by its source id, at `192.0.2.22`
- **THEN** the aliases of both X and Y SHALL be invalidated
- **AND** an `alias_invalidated` identity decision SHALL be recorded for each
- **AND** no two of the three devices SHALL be merged

#### Scenario: A device's own alias is not a conflict
- **GIVEN** devices X and Y each hold a confirmed IP alias of `192.0.2.23`, and Y holds a strong identifier of its own
- **WHEN** a mapper poll resolves device X at `192.0.2.23` by its interface MACs
- **THEN** device X's alias SHALL be left unchanged
- **AND** device Y's alias SHALL be invalidated

#### Scenario: Every lookup takes the same holder
- **GIVEN** devices X and Y each hold a confirmed IP alias of `192.0.2.24`, and Y's was seen more recently
- **WHEN** the sweep, a sync, the resolver or the mapper resolves `192.0.2.24` to one holder
- **THEN** each SHALL resolve it to device Y

#### Scenario: A merge folds an alias both devices hold
- **GIVEN** devices X and Y each hold an IP alias of `192.0.2.25`, X's confirmed and Y's pending
- **WHEN** X is merged into Y
- **THEN** the merge SHALL succeed
- **AND** X's row SHALL be marked `replaced` by Y's
- **AND** Y's row SHALL be confirmed
