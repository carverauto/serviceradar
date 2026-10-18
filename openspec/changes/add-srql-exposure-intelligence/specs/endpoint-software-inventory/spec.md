## ADDED Requirements

### Requirement: Assessment Transitions Are Published On JetStream
The matcher SHALL publish an assessment transition on JetStream whenever an assessment enters or leaves the exact actionable state (`status = active`, `assessment = confirmed`, `disposition = affected`), or when an actionable assessment's installed version, KEV flag, exploit flag, CVSS score, severity or fixed version changes. Assessments whose relevant fields did not change SHALL NOT produce transitions.

**Transactionality.** Each transition SHALL be recorded in a transactional outbox in the same CNPG transaction as the assessment change, and SHALL be relayed at least once.

**Content.** Each transition SHALL carry:
- `transition_seq`, drawn from one sequence;
- `device_uid`, `package_identity_key`, `installed_version`, `cve_id`;
- the device, CVE, package and package-version ordinals, allocated in that transaction;
- the new state and the changed fields, and the reason.

**Device lifecycle.** Device merges and deletions SHALL publish a `device_retired` transition for the retired ordinal.

**Snapshots.** The publisher SHALL support a generation snapshot of all actionable assessments, bracketed by start and end markers.

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
