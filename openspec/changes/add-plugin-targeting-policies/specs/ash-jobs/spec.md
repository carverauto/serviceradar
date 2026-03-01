## ADDED Requirements
### Requirement: Plugin target policy reconciliation jobs
The system SHALL execute plugin target policy reconciliation through AshOban jobs on a recurring schedule.

#### Scenario: Reconciler runs on schedule
- **GIVEN** an enabled plugin target policy with interval settings
- **WHEN** the interval elapses
- **THEN** an AshOban job SHALL execute reconciliation for that policy
- **AND** the job SHALL store a reconcile summary

### Requirement: Reconciler chunks targets for scale
The reconciler SHALL group matched devices by agent and chunk target lists into bounded assignment batches.

#### Scenario: Large target set is chunked
- **GIVEN** a policy query matching 6,000 devices
- **AND** configured `chunk_size` is 100
- **WHEN** reconciliation executes
- **THEN** generated assignments SHALL contain at most 100 targets per assignment
- **AND** total assignments SHALL be approximately `ceil(targets_per_agent / 100)` per agent

### Requirement: Reconciliation is idempotent for unchanged chunks
The reconciler SHALL preserve assignment identities for unchanged chunks between runs.

#### Scenario: No target changes
- **GIVEN** policy query results and chunk boundaries are unchanged
- **WHEN** reconciliation runs
- **THEN** no-op updates SHALL be avoided for unchanged assignments
