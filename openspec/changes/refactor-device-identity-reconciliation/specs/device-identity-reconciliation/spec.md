## ADDED Requirements

### Requirement: Identifier Value Validation and Normalization
The system SHALL validate and normalize every identifier value at the ingestion boundary before it is written to `device_identifiers`. MAC identifier values MUST be atomic (one MAC per row), normalized to 12 uppercase hex characters, and multi-value source fields (e.g. comma-joined MAC lists) MUST be split into individual identifiers. Values failing validation MUST be rejected, counted in telemetry, and MUST NOT create identifier rows.

#### Scenario: Comma-joined MAC list is split into atomic identifiers
- **WHEN** a sync update arrives with `mac` = `001AA0B94040,001422F42A2A,70B3D59EDC93`
- **THEN** three `mac` identifier rows are registered, each a single normalized 12-hex-char value
- **AND** no identifier row contains a comma or exceeds 12 hex characters

#### Scenario: Invalid MAC value is rejected
- **WHEN** an update carries a `mac` value that does not normalize to exactly 12 hex characters
- **THEN** no `mac` identifier row is written
- **AND** a validation-rejection telemetry counter is incremented with the source label

#### Scenario: Confidence derives from evidence
- **WHEN** integration-sourced MAC identifiers are registered
- **THEN** locally-administered MACs (IEEE bit 1 of first octet set) receive `medium` confidence and globally-unique MACs receive `strong` confidence
- **AND** confidence is never hardcoded by the ingest path

### Requirement: Identifier Lifecycle and Cardinality Bounds
The system SHALL bound identifier accumulation per device: a configurable per-(device, identifier_type) cardinality cap enforced at write time with supersede-by-`last_seen` semantics, TTL-based garbage collection for identifiers unseen beyond a configurable window, and a scheduled GC job. The system SHALL emit telemetry for identifier table growth and per-device cardinality, with alert thresholds.

#### Scenario: Cardinality cap supersedes stale identifiers
- **GIVEN** a device at its `mac` cardinality cap
- **WHEN** a new valid MAC is registered for the device
- **THEN** the new identifier is written and the least-recently-seen identifier beyond the cap is retired
- **AND** the retirement is recorded (not a silent delete)

#### Scenario: Unseen identifiers are garbage collected
- **GIVEN** identifiers whose `last_seen` is older than the configured TTL
- **WHEN** the identifier GC job runs
- **THEN** those identifiers are removed and the run logs counts by type and source

#### Scenario: Cardinality anomaly raises an alert
- **WHEN** a device accumulates identifiers at a rate exceeding the configured threshold
- **THEN** an alert/telemetry event is emitted identifying the device and source before the table grows unboundedly

### Requirement: Single Canonical Resolution Path
All ingestion paths (sync, mapper, hypervisor enrichment, wifi, camera, discovery) SHALL resolve device identity exclusively through the identity reconciler. Ingestors MUST NOT create device records directly, MUST NOT implement parallel resolution logic (including IP-based fallback that overrides strong identifiers), and MUST NOT trust pre-set `sr:` device IDs without re-validation against current identifier state.

#### Scenario: Pre-set device ID is re-validated
- **GIVEN** an update arriving with a pre-set `sr:` device_id minted by an upstream component
- **WHEN** the update's strong identifiers resolve to a different canonical device
- **THEN** the reconciler's resolution wins and the pre-set ID is treated as a hint only

#### Scenario: Batch IP fallback cannot override strong identity
- **GIVEN** a batch containing updates with strong identifiers
- **WHEN** identity is resolved for the batch
- **THEN** no update is assigned a device via IP-map fallback when it carries a strong identifier
- **AND** batch-local state cannot collapse distinct strong-identified devices onto one record

#### Scenario: Mapper device creation routes through the reconciler
- **WHEN** the mapper discovers a device for an unresolved IP
- **THEN** the device record is created via the identity reconciler (not direct resource creation)
- **AND** its identifiers are registered in `device_identifiers`

### Requirement: Merge Stability and Oscillation Protection
The system SHALL prevent merge oscillation: weak or medium evidence (including confirmed IP aliases) MUST NOT merge two devices that hold distinct strong identities (e.g. different `agent_id` identifiers); a device pair that has merged in either direction within a configurable cooldown window MUST NOT be re-merged automatically (the attempt is blocked, audited, and alerted); merged-away device IDs MUST NOT be recreated by deterministic UID generation or identifier registration (canonical-alias lookup precedes creation).

#### Scenario: IP alias cannot override agent identity
- **GIVEN** device A holds `agent_id` identifier `agent-k8s-cp2-worker2` and device B holds `agent_id` identifier `agent-k8s-cp2-worker1`
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

### Requirement: Agent Identity Is First-Class and Self-Healing
The system SHALL ensure each distinct connected agent resolves to a distinct canonical device carrying that agent's `agent_id` identifier. A periodic repair job SHALL verify and restore agent↔device linkage (agent registration is not the only linkage opportunity). Merges SHALL preserve per-agent linkage and reassign `device_agent_availability` rows. A device acquiring a second connected agent's `agent_id` identifier SHALL be detected and split rather than silently collapsed.

#### Scenario: Distinct agents never share one device
- **GIVEN** six connected k8s worker agents on six hosts
- **WHEN** their updates are reconciled over time (including pod IP churn and host IP reassignment)
- **THEN** six distinct canonical devices exist, each linked to exactly one agent

#### Scenario: Stale agent identifier is repaired
- **GIVEN** an agent whose `agent_id` identifier points at a device other than the agent's linked device
- **WHEN** the agent link repair job runs
- **THEN** the identifier is re-pointed to the agent's canonical device and the repair is audited

#### Scenario: Pod IP churn does not fragment agent identity
- **GIVEN** a containerized agent whose pod IP changes on every redeploy
- **WHEN** the agent reconnects with a new IP and new hostname suffix
- **THEN** it resolves to its existing canonical device via its `agent_id` identifier
- **AND** no additional device record is created

### Requirement: Cross-Source Identity Bridging
Agent enrollment SHALL register host evidence beyond `agent_id`: the host's interface MAC addresses (subject to observer-exclusion rules), machine identifier when available, and normalized hostname as a medium-confidence corroborating identifier. Hypervisor enrichment SHALL register guest NIC MACs and normalized hostnames through the identity reconciler. Hostname matches MUST only corroborate (never serve as the sole basis for) a merge.

#### Scenario: Agent and Proxmox guest records converge
- **GIVEN** a Proxmox guest record carrying the guest's NIC MAC and hostname
- **AND** an agent running in that guest that registered the same MAC and hostname at enrollment
- **WHEN** both sources have been ingested
- **THEN** they resolve to a single canonical device linked to the agent
- **AND** the device retains both `proxmox` and `agent` discovery sources

#### Scenario: Hostname alone does not merge
- **GIVEN** two devices that share only a normalized hostname
- **WHEN** reconciliation processes updates for either device
- **THEN** the devices are not merged automatically

### Requirement: Stable Versioned Integration Identifiers
Integration-sourced `integration_id` values SHALL be format-versioned and stable across syncs: the value for a given external object MUST NOT change due to renames, NIC changes, or connector restarts. Legacy format generations SHALL be mapped to the current format during reconciliation so connector resumption reconciles with existing records instead of duplicating them. Each external object SHALL produce at most one `integration_id` identifier per device per sync (no per-run or per-batch minting).

#### Scenario: Connector resume does not duplicate guests
- **GIVEN** Proxmox guest records created under a legacy `integration_id` format
- **WHEN** the connector resumes with the current format
- **THEN** each guest resolves to its existing device via the legacy-format mapping
- **AND** no duplicate device records are created

#### Scenario: Batch attribution is per-object
- **WHEN** a 500-update integration batch is ingested
- **THEN** each update's `integration_id` is registered on the device resolved for that update only
- **AND** no single device accumulates the batch's identifiers

### Requirement: Audited Identifier Rebinding
Re-pointing an existing identifier row to a different device SHALL be an explicit, audited operation. Bulk upserts MUST NOT silently replace `device_id` on conflict.

#### Scenario: Identifier rebind writes an audit record
- **WHEN** reconciliation determines an identifier must move from device A to device B
- **THEN** the move is recorded with the identifier, both device IDs, the reason, and the triggering source

### Requirement: Production Identity Data Remediation
A one-time, audited remediation SHALL: remove invalid (multi-value/malformed) `mac` identifier rows after extracting a valid fallback identifier for blob-only devices; remove test-artifact agents and devices from production data; repair agent↔device links damaged by historical over-merges (including recreating tombstoned host devices); invalidate poisoned IP alias states; and map legacy Proxmox integration identifiers to the current format. The migration SHALL produce a manifest of affected rows sufficient for targeted rollback.

#### Scenario: Blob purge preserves device resolvability
- **GIVEN** a device whose only identifiers are comma-joined MAC blobs
- **WHEN** the remediation runs
- **THEN** at least one valid atomic MAC identifier is registered for the device before its blob rows are deleted

#### Scenario: Collapsed worker agents are restored
- **GIVEN** multiple connected agents linked to a single chimera device by historical merges
- **WHEN** the remediation runs
- **THEN** each agent is linked to its own host device with correct hostname and IP
- **AND** the chimera's poisoned alias states are invalidated

## MODIFIED Requirements

### Requirement: IP Alias Resolution
The system SHALL resolve IP-only device updates using confirmed IP aliases before generating a new device ID. Alias-based resolution and alias-triggered merges MUST be subordinate to strong identity: a confirmed alias MUST NOT cause a merge between devices holding distinct strong identifiers, and alias states that conflict with strong identity SHALL be invalidated.

#### Scenario: Interface-discovered IP alias resolves a sweep host
- **GIVEN** a device `sr:<uuid>` has a confirmed IP alias `216.17.46.98` recorded from interface discovery
- **WHEN** a sweep result arrives with host IP `216.17.46.98` and no strong identifiers
- **THEN** DIRE SHALL resolve the update to the canonical device ID
- **AND** SHALL NOT create a new device record for the alias IP

#### Scenario: Strong-ID update conflicts with confirmed IP alias
- **GIVEN** a device update with a strong identifier resolves to device ID X
- **AND** the update IP is a confirmed alias for device ID Y (Y != X)
- **AND** device Y does NOT hold a distinct strong identifier conflicting with X's
- **WHEN** DIRE processes the update
- **THEN** DIRE SHALL merge the alias device into the strong-ID canonical device

#### Scenario: Alias conflicting with strong identity is invalidated
- **GIVEN** a device update with strong identifier resolving to device X
- **AND** the update IP is a confirmed alias for device Y, where Y holds a different `agent_id` identifier
- **WHEN** DIRE processes the update
- **THEN** no merge occurs
- **AND** the alias state for that IP on device Y is invalidated and the conflict is audited

### Requirement: Scheduled Reconciliation Backfill
The system SHALL run a scheduled reconciliation job that merges existing duplicate devices sharing strong identifiers and logs summary statistics for each run. The job SHALL be bounded (streaming/batched, never loading the full identifier table into memory), SHALL apply the same merge policy gates as ingest-time reconciliation (confidence rules, strong-identity guards, oscillation cooldown), and its scheduling health SHALL be monitored such that a silently-dead schedule raises an alert.

#### Scenario: Scheduled reconciliation merges duplicates and logs results
- **GIVEN** two device IDs that share the same strong identifier within a partition
- **WHEN** the reconciliation job runs
- **THEN** the non-canonical device SHALL be merged into the canonical device subject to merge policy gates
- **AND** the job SHALL emit logs summarizing the number of duplicates scanned and merges performed

#### Scenario: Backfill respects merge policy
- **GIVEN** two devices whose only shared evidence is medium-confidence (e.g. locally-administered MAC or bare IP)
- **WHEN** the reconciliation job runs
- **THEN** the devices are NOT merged

#### Scenario: Dead schedule is detected
- **GIVEN** the reconciliation job has not enqueued within twice its configured interval
- **WHEN** schedule health monitoring evaluates
- **THEN** an alert is raised identifying the dead schedule
