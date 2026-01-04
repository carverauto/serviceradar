## ADDED Requirements

### Requirement: Summary snapshot isolation
ServiceRadar MUST return sweep summaries whose `HostResult` entries do not alias internal mutable state.

#### Scenario: GetSummary returns safe-to-read host snapshots
- **GIVEN** a sweeper result processor has processed at least one result
- **WHEN** a caller invokes `GetSummary`
- **THEN** the returned `SweepSummary.Hosts` entries MUST be safe to read after the call returns (without holding internal shard locks)
- **AND** concurrent result processing MUST NOT cause data races when the caller reads `PortResults`, `PortMap`, or `ICMPStatus`

#### Scenario: Streamed HostResult values remain safe after shard locks are released
- **GIVEN** a caller consumes host snapshots from a summary streaming API
- **WHEN** the streaming method has returned and internal locks have been released
- **THEN** the previously received `HostResult` values MUST remain safe to read while result processing continues concurrently

#### Scenario: Caller mutation does not affect subsequent summaries
- **GIVEN** a caller has received a sweep summary containing a `HostResult`
- **WHEN** the caller mutates the returned host data (e.g., appends to `PortResults` or edits `PortMap`)
- **THEN** subsequent summaries MUST reflect only internally maintained state, not caller mutations

