## ADDED Requirements

### Requirement: Monotonic Identity Revision
Every device SHALL carry a monotonic `identity_revision` that is incremented on every identity
transition. A transition is any change to which physical thing a device id names or which
identifiers it owns: merge (both the source and the survivor), unmerge, split, alias
invalidation, identifier reassignment, soft delete, and restore.

The revision SHALL be incremented atomically, SHALL NOT decrease, and SHALL NOT be incremented
by writes that do not change identity — availability updates, heartbeat touches and gateway
syncs are not transitions.

#### Scenario: Merge bumps both devices
- **GIVEN** device A with `identity_revision` 4 and device B with `identity_revision` 7
- **WHEN** A is merged into B
- **THEN** A's revision is greater than 4
- **AND** B's revision is greater than 7

#### Scenario: Non-identity writes do not bump
- **GIVEN** a device with a known `identity_revision`
- **WHEN** its availability, last-seen timestamp or gateway sync state is updated
- **THEN** the `identity_revision` is unchanged

#### Scenario: Concurrent transitions do not lose a bump
- **GIVEN** two identity transitions committing concurrently against one device
- **WHEN** both complete
- **THEN** the resulting revision reflects both increments

### Requirement: Pinned Identity Resolution
Resolution SHALL be able to return a device id together with the `identity_revision` observed
at resolution time, so that a caller which resolves once and writes later can detect that its
identity decision went stale.

A write that pins a revision and finds it superseded SHALL re-resolve and retry at most once,
then abandon the write and emit telemetry identifying the pipeline. It SHALL NOT raise, because
the highest-volume consumers are batch pipelines where one raised device fails the whole batch.
It SHALL NOT discard silently, because several consumers are state machines whose dropped
transitions never recover.

#### Scenario: Stale pinned revision is detected at write time
- **GIVEN** a consumer that resolved a device and pinned its revision
- **AND** the device is merged before the consumer writes
- **WHEN** the consumer attempts its write
- **THEN** the write does not land against the merged-away device
- **AND** the consumer re-resolves and retries once

#### Scenario: A stale write that cannot be re-resolved is reported
- **GIVEN** a pinned write whose device cannot be re-resolved to a live device
- **WHEN** the write is abandoned
- **THEN** telemetry records the pipeline, the device id and the revision mismatch

#### Scenario: Repeated transitions during one write are not retried indefinitely
- **GIVEN** a write whose pinned revision is superseded twice
- **WHEN** the second retry also observes a superseded revision
- **THEN** the write is abandoned and reported rather than retried again

### Requirement: Identity Transition Events
An identity transition SHALL publish an event naming both the previous and the resulting
canonical device id, so caches and subscribers can invalidate. A generic device-updated
broadcast is not sufficient, because it does not say which device a stale id now resolves to.

#### Scenario: A merge publishes both device ids
- **GIVEN** device A is merged into device B
- **WHEN** the merge commits
- **THEN** an identity transition event is published naming A as the previous id and B as the
  resulting canonical id

#### Scenario: Node-local identity caches do not serve a merged-away mapping
- **GIVEN** a clustered deployment where another node has cached a resolution for device A
- **WHEN** A is merged into B and the transition event is delivered
- **THEN** that node stops serving the cached pre-merge mapping

### Requirement: Repair of Stranded Device References
The system SHALL provide a resumable repair that repoints rows still referencing a
merged-away device to its terminal canonical device, for a declared inventory of device-keyed
tables. The inventory SHALL be explicit rather than derived by scanning for column names,
because some device references are deliberately historical and MUST NOT be repointed.

The repair SHALL be idempotent, safe to re-run, and SHALL support a dry-run mode that reports
what it would change without changing it. It SHALL be batched and rate-limited so that it can
run without degrading foreground database traffic.

#### Scenario: Dry run changes nothing
- **GIVEN** rows referencing devices merged away in the past
- **WHEN** the repair runs in dry-run mode
- **THEN** a per-table report of candidate rows is produced
- **AND** no row is modified

#### Scenario: Repair follows a chain of merges to the terminal device
- **GIVEN** device A was merged into B, and B was later merged into C
- **WHEN** the repair runs in apply mode
- **THEN** rows referencing A are repointed to C

#### Scenario: Repair is interruptible and resumable
- **GIVEN** a repair run that is interrupted partway
- **WHEN** it is started again
- **THEN** it resumes without repeating completed work and without skipping rows

#### Scenario: Deliberately historical references are not repointed
- **GIVEN** a table whose device reference records what was observed at the time
- **WHEN** the repair runs
- **THEN** that table is not modified, because it is not in the declared inventory

## MODIFIED Requirements

### Requirement: Merge Preserves Inventory Associations
The system SHALL reassign inventory-linked records to the canonical device ID during a merge,
and SHALL leave no live record referencing the merged-away device for any table in the
declared reassignment inventory.

Where a record cannot be reassigned because its identity is content-addressed on the device
id, the merge SHALL record lineage sufficient for the owning subsystem to continue or close
that record deliberately, rather than leaving it orphaned.

A merge that fails partway SHALL leave no partial reassignment: either every reassignment and
the tombstone commit together, or none of them do.

#### Scenario: Interface records move to canonical device
- **GIVEN** two device IDs that each have `discovered_interfaces` records
- **WHEN** DIRE merges the non-canonical device into the canonical device
- **THEN** all `discovered_interfaces` records SHALL reference the canonical device ID

#### Scenario: Interface settings follow their interfaces
- **GIVEN** a device with operator-configured interface threshold settings
- **WHEN** that device is merged into another
- **THEN** the settings reference the canonical device ID
- **AND** interface threshold evaluation continues to run against them

#### Scenario: A failed merge leaves no partial reassignment
- **GIVEN** a merge whose reassignment chain fails partway
- **WHEN** the merge returns an error
- **THEN** no identifier has been reassigned
- **AND** the source device is neither tombstoned nor missing
- **AND** no merge audit row is recorded
