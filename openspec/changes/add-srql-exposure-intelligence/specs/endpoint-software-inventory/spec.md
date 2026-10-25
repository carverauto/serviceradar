## ADDED Requirements

### Requirement: Assessment Transitions Are Published On JetStream
The matcher SHALL publish an assessment transition on JetStream whenever an assessment enters or leaves the exact actionable state (`status = active`, `assessment = confirmed`, `disposition = affected`), or when an actionable assessment's installed version, KEV flag, exploit flag, CVSS score, severity, fixed version, or source scope changes. Assessments whose relevant fields and device lifecycle did not change SHALL NOT produce transitions. A non-actionable assessment's source-scope change SHALL NOT publish a transition.

**Transactionality.** Each transition SHALL be recorded in a transactional outbox in the same CNPG transaction as the assessment change, and SHALL be relayed at least once. The age of the oldest unrelayed outbox row SHALL be exported, and exceeding its bound (default 10 minutes) SHALL raise a health alert. A transaction that physically deletes an assessment row SHALL draw a new `transition_seq`, greater than the key's last one, publish a transition with the explicit `resolved` state at that sequence, and record the key, the `resolved` state and that new sequence in `platform.exposure_fact_watermarks`. A terminal transition SHALL NOT reuse the key's last sequence.

**Content.** Each transition SHALL carry:
- `transition_seq`, drawn from one sequence while the transaction holds the assessment row's lock, and stored on the assessment row as its last transition sequence;
- `transition_xid`, the producing transaction's `pg_current_xact_id()`;
- `device_lifecycle_seq`, the source device lifecycle sequence (initially zero);
- `device_uid`, `package_identity_key`, `installed_version`, `cve_id`;
- the device, CVE, package and package-version ordinals, allocated in that transaction;
- the complete after-image of the fact (state, installed version and its ordinal, severity, CVSS, KEV, exploit and fix flags, source scope, exposure and resolution times), never only the changed fields;
- the list of changed fields, and the reason.

**Device lifecycle.** Device merges and deletions SHALL publish a `device_retired` transition for the retired ordinal, with a new `transition_seq` drawn in the transaction that tombstones the ordinal and recorded on the ordinal as its `retired_seq`. It carries the explicit `retired` state, and no later assessment transition SHALL be produced while the ordinal remains tombstoned. An authorized restoration SHALL retain the fleet ordinal and publish a newer `device_restored` lifecycle transition in the restoring transaction. Lifecycle and assessment publication SHALL serialize per device. Restoration SHALL durably schedule bounded republication of current actionable assessments with fresh sequences and the restored lifecycle sequence; completion SHALL be part of snapshot readiness. Repeated unchanged lifecycle writes SHALL publish nothing. These rules SHALL also cover temporary deactivation, raw SQL writers, retention cleanup and authorized unmerge, without changing restore authorization.

**Retained publications.** Latest assessment publications and deletion-watermark terminals follow *Exposure Is Rebuildable And Reconciled Against The Assessment Store*. They are source publication and recovery records only.

**Snapshots.** The publisher SHALL support a generation snapshot of all actionable assessments, bracketed by start and end markers. The snapshot SHALL read in one `REPEATABLE READ` transaction, record that transaction's `pg_current_snapshot()` on the end marker, and emit each assessment with its last `transition_seq` and `transition_xid`, plus a terminal watermark for every other fact key it knows, from non-actionable assessment rows and `platform.exposure_fact_watermarks`, and the latest lifecycle state and sequence, retaining the last `retired_seq`, for each ordinal whose lifecycle changed. Assessment snapshot rows SHALL carry their lifecycle sequence.

#### Scenario: Upgrade that fixes the CVE emits a resolution
- **GIVEN** an actionable assessment for a package at version 1.0
- **WHEN** the package is upgraded to the fixed version and the assessment resolves
- **THEN** one transition with state `resolved` and a new `transition_seq` is relayed to JetStream

#### Scenario: Unchanged recompute emits nothing
- **GIVEN** the matcher re-evaluates a device whose assessments did not change
- **WHEN** the run completes
- **THEN** no transitions are published for that device

#### Scenario: Source scope change publishes a new after-image
- **GIVEN** an acknowledged actionable assessment whose source scope is `host`
- **WHEN** only its source scope changes
- **THEN** a new transition carries the new scope, the previous fact attributes, and a greater sequence
- **AND** repeating that same scope publishes nothing

#### Scenario: Rolled-back transaction emits nothing
- **GIVEN** an assessment change whose transaction rolls back
- **WHEN** the outbox relay runs
- **THEN** no transition is published for it

#### Scenario: Deletion draws a new sequence
- **GIVEN** an actionable assessment whose last transition has sequence 10
- **WHEN** its row is physically deleted
- **THEN** a `resolved` transition with a sequence greater than 10 is published, and the same key, state and sequence are recorded in `platform.exposure_fact_watermarks`

#### Scenario: Concurrent changes to one assessment are sequenced in commit order
- **GIVEN** two transactions change the same assessment
- **WHEN** both commit
- **THEN** the transaction that committed later carries the higher `transition_seq`

### Requirement: Running Executables Resolve To Owning Packages
The agent SHALL resolve the executable of each listening or attributed process to its owning installed package. It SHALL use the package manager's file ownership read inside the process's own root filesystem, so a containerized process resolves against its image's package database. A package SHALL own the executable only when one of its listed paths, resolved inside that root, has the executable's device and inode. Directory symlinks inside that root SHALL be followed; a listed path whose final component is itself a symlink SHALL own nothing, because the file it points to is listed by its own package. The agent SHALL cache each result keyed by process root, executable device and inode, valid while the file's mtime and size and that root's package-database state are unchanged, SHALL neither use nor store a cache entry for a read where the kernel reports the executable deleted, and SHALL resolve once per cache entry, never once per connection. The resolved inventory package reference SHALL be carried by every message that reports a process owner: ownership lease owner records and connection summary rows (from `stream-flow-attribution-via-ownership-index`, landing in #5738), and, until those exist, `FlowAttributionEvent` and `ProcessSnapshotEntry`. The reference SHALL carry a resolution state, which SHALL be the first that applies in this order: `NOT_PERMITTED` when procfs or the root denied access; `UNKNOWN` when the process exited, or a procfs or root read failed other than by an access denial, or the kernel reports the executable deleted (its file was unlinked or replaced, for example by a package upgrade or removal, while the process kept running, whether or not a package ever owned it), or the root has no package database, or a database was unreadable, changing or truncated (an rpm write-ahead log is read as part of its database, never treated as pending); `UNSUPPORTED_DB` when no supported package database is present and an unsupported one is; `RESOLVED` when a supported database lists a path with the executable's device and inode; `NOT_FOUND` when the executable is still linked on disk, every supported database present was read completely, and no listed path has its inode, even if an unsupported database is also present. Only a `RESOLVED` reference SHALL name a package. An unresolved executable SHALL NOT be guessed from the process name or command line.

#### Scenario: Listener resolves to its package
- **GIVEN** a process listening on TCP 22 whose executable is installed by an inventory package
- **WHEN** netprobe emits the flow attribution event and the listener snapshot entry
- **THEN** both carry that package's inventory reference

#### Scenario: Lease and summary carry the reference once they exist
- **GIVEN** the ownership lease and connection summary messages of `stream-flow-attribution-via-ownership-index` exist
- **WHEN** netprobe emits a lease owner record or a connection summary row for a resolved process
- **THEN** it carries the same inventory package reference

#### Scenario: Resolution is cached per inode
- **GIVEN** 1,000 connections handled by the same executable inode in one process root in an interval, while the executable stays linked on disk and the file's mtime and size and that root's package-database state are unchanged
- **WHEN** they are summarized
- **THEN** package ownership is resolved at most once for that inode

#### Scenario: Unowned executable stays unknown
- **GIVEN** an executable that is still linked on disk, in a root where every supported package database present was read completely (an unsupported one may also be present), and no listed path has its inode
- **WHEN** it is resolved
- **THEN** the reference state is `NOT_FOUND`, it names no package, and no name-based guess is made

#### Scenario: Replaced binary is not attributed to the new package
- **GIVEN** a process still running a binary whose package was upgraded, so the installed path now holds a different inode and the kernel reports the running executable deleted
- **WHEN** it is resolved
- **THEN** the reference state is `UNKNOWN` and it names no package

#### Scenario: Unsupported package database is reported
- **GIVEN** a host with no supported package database whose rpm database uses the BerkeleyDB backend
- **WHEN** an executable is resolved
- **THEN** the reference state is `UNSUPPORTED_DB` and it names no package
