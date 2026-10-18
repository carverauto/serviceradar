## ADDED Requirements

### Requirement: Assessment Transitions Are Published On JetStream
The matcher SHALL publish an assessment transition on JetStream whenever an assessment enters or leaves the exact actionable state (`status = active`, `assessment = confirmed`, `disposition = affected`), or when an actionable assessment's installed version, KEV flag, exploit flag, CVSS score, severity or fixed version changes. Assessments whose relevant fields did not change SHALL NOT produce transitions.

**Transactionality.** Each transition SHALL be recorded in a transactional outbox in the same CNPG transaction as the assessment change, and SHALL be relayed at least once. The age of the oldest unrelayed outbox row SHALL be exported, and exceeding its bound (default 10 minutes) SHALL raise a health alert. A transaction that physically deletes an assessment row SHALL draw a new `transition_seq`, greater than the key's last one, publish a transition with the explicit `resolved` state at that sequence, and record the key, the `resolved` state and that new sequence in `platform.exposure_fact_watermarks`. A terminal transition SHALL NOT reuse the key's last sequence.

**Content.** Each transition SHALL carry:
- `transition_seq`, drawn from one sequence while the transaction holds the assessment row's lock, and stored on the assessment row as its last transition sequence;
- `transition_xid`, the producing transaction's `pg_current_xact_id()`;
- `device_uid`, `package_identity_key`, `installed_version`, `cve_id`;
- the device, CVE, package and package-version ordinals, allocated in that transaction;
- the complete after-image of the fact (state, installed version and its ordinal, severity, CVSS, KEV, exploit and fix flags, source scope, exposure and resolution times), never only the changed fields;
- the list of changed fields, and the reason.

**Device lifecycle.** Device merges and deletions SHALL publish a `device_retired` transition for the retired ordinal, with a new `transition_seq` drawn in the transaction that tombstones the ordinal and recorded on the ordinal as its `retired_seq`. It carries the explicit `retired` state, and no later transition SHALL be produced for the ordinal.

**Snapshots.** The publisher SHALL support a generation snapshot of all actionable assessments, bracketed by start and end markers. The snapshot SHALL read in one `REPEATABLE READ` transaction, record that transaction's `pg_current_snapshot()` on the end marker, and emit each assessment with its last `transition_seq` and `transition_xid`, plus a terminal watermark for every other fact key it knows, from non-actionable assessment rows and `platform.exposure_fact_watermarks`, and a retirement marker with its `retired_seq` for every tombstoned ordinal.

#### Scenario: Upgrade that fixes the CVE emits a resolution
- **GIVEN** an actionable assessment for a package at version 1.0
- **WHEN** the package is upgraded to the fixed version and the assessment resolves
- **THEN** one transition with state `resolved` and a new `transition_seq` is relayed to JetStream

#### Scenario: Unchanged recompute emits nothing
- **GIVEN** the matcher re-evaluates a device whose assessments did not change
- **WHEN** the run completes
- **THEN** no transitions are published for that device

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
The agent SHALL resolve the executable of each listening or attributed process to its owning installed package. It SHALL use the package manager's file ownership, or container image layer metadata when available, and SHALL resolve once per executable inode and cache the result, never once per connection. The resolved inventory package reference SHALL be attached to ownership lease owner records and to connection summary rows. An unresolved executable SHALL be reported as unknown and SHALL NOT be guessed from the process name or command line.

#### Scenario: Listener resolves to its package
- **GIVEN** a process listening on TCP 22 whose executable is installed by an inventory package
- **WHEN** netprobe emits the listener lease and the connection summaries
- **THEN** both carry that package's inventory reference

#### Scenario: Resolution is cached per inode
- **GIVEN** 1,000 connections handled by the same executable inode in an interval
- **WHEN** they are summarized
- **THEN** package ownership is resolved at most once for that inode

#### Scenario: Unowned executable stays unknown
- **GIVEN** an executable that no package manager owns
- **WHEN** it is resolved
- **THEN** the package reference is unknown, and no name-based guess is made
