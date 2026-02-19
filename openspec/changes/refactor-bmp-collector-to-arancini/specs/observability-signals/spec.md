## ADDED Requirements
### Requirement: Arancini-backed BMP Collector Runtime
The BMP ingestion runtime SHALL use an Arancini-based collector implementation while preserving ServiceRadar's existing causal ingestion contract.

#### Scenario: Collector uses external Arancini dependency
- **GIVEN** ServiceRadar builds the BMP collector
- **WHEN** the collector dependency graph is resolved
- **THEN** it SHALL consume `arancini-lib` as an external dependency
- **AND** it SHALL NOT require the `arancini` repository to be vendored into the ServiceRadar monorepo

#### Scenario: Collector publishes Broadway-compatible BMP events
- **GIVEN** raw BMP routing messages are ingested
- **WHEN** events are published to JetStream
- **THEN** the collector SHALL publish to `bmp.events.*` subjects within stream `BMP_CAUSAL`
- **AND** published payloads SHALL remain compatible with the Broadway causal signals processor

### Requirement: BMP Publish Contract Stability
The BMP collector SHALL maintain stable subject/event mappings for replay-safe downstream processing.

#### Scenario: Route update event mapping remains stable
- **GIVEN** a decoded routing update event
- **WHEN** the collector publishes the event
- **THEN** it SHALL use subject `bmp.events.route_update`
- **AND** the event envelope SHALL include deterministic event identity fields

#### Scenario: Route withdraw event mapping remains stable
- **GIVEN** a decoded routing withdraw event
- **WHEN** the collector publishes the event
- **THEN** it SHALL use subject `bmp.events.route_withdraw`
- **AND** correlation fields required for topology/causal joins SHALL be preserved

### Requirement: BMP Ingest Backpressure and Ack Safety
The BMP collector SHALL apply bounded backpressure and publish-ack handling so burst ingress does not silently drop events.

#### Scenario: Burst ingest triggers bounded buffering
- **GIVEN** BMP event volume exceeds immediate publish throughput
- **WHEN** the collector's publish queue grows
- **THEN** the collector SHALL apply bounded buffering/backpressure controls
- **AND** it SHALL emit telemetry for queue depth and publish outcomes

#### Scenario: Publish ack timeout is handled explicitly
- **GIVEN** JetStream acknowledgements exceed configured timeout
- **WHEN** a publish ack timeout occurs
- **THEN** the collector SHALL surface an explicit error/metric
- **AND** it SHALL avoid reporting the timed-out publish as a successful delivery
