# sweeper Specification

## Purpose
TBD - created by archiving change fix-sweeper-summary-shallow-copy. Update Purpose after archive.
## Requirements
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

### Requirement: Sweep Results Push to Agent-Gateway

The agent SHALL push sweep results to the agent-gateway using the existing gRPC push protocol, emitting results only when sweep activity occurs and optionally providing progress batches for large sweeps.

#### Scenario: Agent pushes sweep completion results
- **GIVEN** an agent that has completed a sweep execution
- **WHEN** the sweep results are finalized
- **THEN** the agent SHALL push a completion batch via gRPC
- **AND** the batch SHALL include total hosts scanned, hosts available, and hosts failed
- **AND** the agent SHALL NOT emit periodic result pushes when no sweep has executed

#### Scenario: Agent pushes progress batches during large sweeps
- **GIVEN** a sweep execution with a large target set
- **WHEN** the agent reaches the configured progress threshold (count or time)
- **THEN** the agent SHALL push a progress batch via gRPC
- **AND** the batch SHALL include cumulative totals for the execution so far
- **AND** progress batches SHALL be rate-limited by configuration

### Requirement: Gateway Forwards Sweep Results to Core

The agent-gateway SHALL forward sweep results to core-elx for processing through DIRE and device enrichment.

#### Scenario: Gateway receives and forwards results
- **GIVEN** the agent-gateway receives sweep results from an agent
- **WHEN** processing the status push
- **THEN** the gateway SHALL extract tenant from mTLS certificate
- **AND** forward results to core-elx via RPC with tenant context
- **AND** use streaming/chunking for large payloads

#### Scenario: Gateway handles offline core gracefully
- **GIVEN** sweep results received while core-elx is unavailable
- **WHEN** the forward attempt fails
- **THEN** the gateway SHALL buffer results with configurable retention
- **AND** retry forwarding when core becomes available
- **AND** drop oldest results if buffer is full

---

### Requirement: Core Processes Sweep Results via DIRE

The core SHALL process sweep results through DIRE to update device records with availability information.

#### Scenario: Update device availability from sweep
- **GIVEN** sweep results indicating host availability
- **WHEN** core processes the results
- **THEN** DIRE SHALL match hosts to existing devices by IP
- **AND** update `ocsf_devices.is_available` based on sweep result
- **AND** update `ocsf_devices.last_seen_time` for available devices
- **AND** add "sweep" to `discovery_sources` array

#### Scenario: Ignore sweep hosts not in inventory
- **GIVEN** sweep results for a host not in device inventory
- **WHEN** core processes the results
- **THEN** DIRE SHALL NOT create a new device record
- **AND** the host result SHALL be excluded from inventory updates
- **AND** the host result SHALL NOT create device or alias records

#### Scenario: Enrich device with port information
- **GIVEN** sweep results with TCP port scan data
- **WHEN** core processes the results
- **THEN** the device metadata SHALL be updated with open ports
- **AND** device type MAY be inferred from port signatures (e.g., port 22 = likely server)

### Requirement: Agent Config Polling

The agent SHALL poll for sweep configuration from the agent-gateway instead of reading from KV store or local files.

#### Scenario: Agent polls for config on startup
- **GIVEN** an agent starting up
- **WHEN** initializing the sweep service
- **THEN** the agent SHALL call `GetConfig` on the gateway
- **AND** receive compiled sweep configuration
- **AND** apply the configuration to the sweeper

#### Scenario: Agent polls periodically for config updates
- **GIVEN** a running agent
- **WHEN** the config poll interval elapses
- **THEN** the agent SHALL call `GetConfig` with current config hash
- **AND** only download new config if hash differs
- **AND** apply updated configuration dynamically

#### Scenario: Fallback to file config when gateway unavailable
- **GIVEN** an agent unable to reach the gateway
- **WHEN** config poll fails
- **THEN** the agent SHALL use file-based config as fallback
- **AND** continue polling the gateway for updates
- **AND** apply gateway config when connection is restored

