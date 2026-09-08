# sweep-jobs

## ADDED Requirements

### Requirement: Sweep Port Coverage Persistence

The system SHALL persist the full set of ports a sweep attempted against a
host, not only the ports found open, so that a requested protocol can be
distinguished from an observed protocol outcome.

#### Scenario: Agent reports a mix of open and closed ports
- **GIVEN** a sweep group configured for TCP ports 3001, 443 and 4502
- **WHEN** an agent reports a host with 443 open and 3001 and 4502 not
  responding
- **THEN** the stored host result SHALL record all three ports as scanned
- **AND** SHALL record only 443 as open
- **AND** the closed or no-response ports SHALL be derivable as the scanned
  ports minus the open ports

#### Scenario: Host with no open ports is distinguishable from host never scanned
- **GIVEN** a TCP sweep of a host that refuses every configured port
- **WHEN** the result is ingested
- **THEN** the host result SHALL record the attempted ports as scanned
- **AND** SHALL record an empty open port set
- **AND** an operator SHALL be able to tell this apart from a host that was
  swept by ICMP only, for which no TCP ports were scanned

#### Scenario: Result carries its own vantage point and group identity
- **GIVEN** an ingested sweep host result
- **WHEN** it is stored
- **THEN** it SHALL carry the agent identifier and sweep group identifier of the
  execution that produced it
- **AND** results SHALL be groupable by agent and by sweep group without joining
  the execution row

#### Scenario: Ingest requires no agent change
- **GIVEN** an agent reporting per-port outcomes in the existing payload shape
- **WHEN** the results are ingested
- **THEN** the scanned port set SHALL be derived from the per-port outcomes
  already present in that payload
- **AND** no change to the agent, proto or wire format SHALL be required

### Requirement: Long-Term Sweep Coverage Rollup

The system SHALL maintain a per-day rollup of sweep coverage keyed by device,
sweep group and agent, so that overlap and last-writer questions remain
answerable after raw host results are purged.

#### Scenario: Daily rollup precedes cleanup
- **GIVEN** sweep host results retained for 7 days
- **WHEN** the daily maintenance jobs run
- **THEN** the rollup SHALL be written before the cleanup worker deletes
  eligible rows
- **AND** no day SHALL be deleted from raw results before it has been rolled up

#### Scenario: Rollup preserves per-group and per-agent identity
- **GIVEN** one device swept on the same day by two different sweep groups
  through the same agent
- **WHEN** the rollup is written
- **THEN** it SHALL contain a separate row per sweep group
- **AND** neither group's coverage SHALL overwrite the other's

#### Scenario: Rollup is idempotent
- **GIVEN** a rollup that has already been written for a day
- **WHEN** the worker runs again for that same day, whether by retry or by
  manual re-run
- **THEN** the resulting rows SHALL be unchanged
- **AND** counts SHALL NOT be double-counted

#### Scenario: Rollup outlives raw results
- **GIVEN** a sweep host result older than the raw retention window
- **WHEN** an operator queries coverage history for that device
- **THEN** the rolled-up counts, port sets and mode sets SHALL still be
  available for the configured rollup retention

## MODIFIED Requirements

### Requirement: Sweep Job Execution Tracking

The system SHALL track sweep job execution status and history with accurate host
totals and availability counts derived from sweep results, and SHALL retain the
sweep group, agent and protocol context needed to attribute each result.

#### Scenario: Agent reports sweep completion
- **GIVEN** an agent completing a sweep job
- **WHEN** the sweep finishes
- **THEN** core SHALL record total hosts scanned, hosts available, and hosts failed for the execution
- **AND** the completion time and duration SHALL be recorded
- **AND** the values SHALL reflect cumulative results for the execution (not per-batch deltas)

#### Scenario: Active scan progress updates
- **GIVEN** an in-progress sweep execution
- **WHEN** progress batches are ingested
- **THEN** core SHALL update the execution with cumulative progress metrics
- **AND** the Active Scans UI SHALL display the current totals and completion percentage

#### Scenario: Execution retains attribution context
- **GIVEN** a completed sweep execution
- **WHEN** its results are inspected
- **THEN** the execution SHALL identify the sweep group, the agent that ran it,
  and the config version in force
- **AND** each host result belonging to it SHALL carry the requested sweep modes
  alongside the observed per-mode outcome
