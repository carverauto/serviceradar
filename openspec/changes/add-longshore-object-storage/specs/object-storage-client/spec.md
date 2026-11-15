## ADDED Requirements

### Requirement: Bounded asynchronous Longshore bridge
ServiceRadar SHALL expose Longshore through Rustler with bounded retained bytes and operations, asynchronous correlated completion, and no network, buffer or shutdown waits on BEAM normal schedulers.

#### Scenario: Storage stalls or the caller exits
- **WHEN** admitted work remains physically outstanding after a caller exits or times out
- **THEN** its resource budget remains charged until completion or qualified termination
- **AND** excess work receives explicit backpressure without an unbounded queue

#### Scenario: Runtime is unsupported
- **WHEN** required io_uring, memory or TLS capabilities are unavailable
- **THEN** initialization reports an unsupported state without weakening deployment security

### Requirement: Archive authority and integrity preservation
ServiceRadar SHALL activate Longshore archive operations only after proving the existing dispatch, deadline, immutable identity, encryption, integrity and preservation contracts through its public API.

#### Scenario: Provider outcome is uncertain
- **WHEN** a response is lost or an operation cannot be proven terminated
- **THEN** the outcome remains unknown and local data is preserved
- **AND** neither an automatic retry nor a fallback transport creates a new ungranted dispatch

#### Scenario: Public client cannot express the required operation
- **WHEN** a required precondition, response identity or verification property is unavailable
- **THEN** archive activation remains unavailable for that operation until an upstream change is merged and qualified

### Requirement: Measured native and Rustler performance
ServiceRadar SHALL benchmark the native Longshore client, Rustler bridge and full recording path with equivalent synthetic workloads, explicit resource bounds and declared acceptance budgets before claiming performance qualification.

#### Scenario: Compare the bridge with published benchmarks
- **WHEN** reporting Longshore integration performance
- **THEN** the report identifies the pinned upstream sources and same-host paired native/NIF measurements
- **AND** records TLS, checksum, object size, concurrency, hardware, network, retry and verification differences
- **AND** reports goodput, latency distributions, CPU cost, memory and queue pressure with repeated-run variance

#### Scenario: A stage limits throughput
- **WHEN** a performance budget fails or the generator, peer or network masks bridge overhead
- **THEN** the report marks the gate failed or inconclusive, identifies measured evidence and profiles the limiting stage
- **AND** does not infer recorder capacity from published native throughput or a single live camera

### Requirement: Recording dogfood evidence
ServiceRadar SHALL verify a bounded selected-camera recording through object readback, independent decode, authorized catalog playback and service restart before claiming the Longshore recording milestone complete.

#### Scenario: Upload succeeds without playable evidence
- **WHEN** an object write succeeds but integrity, publication or playback verification is missing
- **THEN** the milestone remains incomplete and the local recording remains preserved
- **AND** live media, credentials and operational identifiers remain outside committed artifacts

