## ADDED Requirements

### Requirement: Documented fleet-scale ingestion target
ServiceRadar SHALL document its supported ingestion target as explicit per-signal rates, burst factors, per-node budgets and the warehouse storage implied by the default one-year StarRocks retention, separately for installations with StarRocks enabled and for CNPG-only installations, and SHALL validate the StarRocks target with the fleet-scale synthetic load gate before every release cut.

#### Scenario: CNPG-only ceiling is stated
- **WHEN** an operator reads the capacity documentation for an installation without StarRocks
- **THEN** it SHALL state the supported sustained log record rate for that configuration

#### Scenario: Storage at the design point is stated
- **WHEN** an operator reads the capacity documentation for a 100,000-device installation with StarRocks
- **THEN** it SHALL state the object storage that one year of default retention implies, about 0.5-1 PB
- **AND** it SHALL name the per-dataset retention settings that reduce it

### Requirement: Telemetry streams are signal-separated and elastic
Logs, events, OpenTelemetry signals and metrics SHALL be carried on separate JetStream streams, replicated as the profile's replica count allows. Their subjects SHALL carry a block from the same fixed block layout as alert candidates, hashed from the source device or address.
A CNPG runtime setting per signal SHALL set the number of physical streams, defaulting to one, and another SHALL set each stream's size. For every active profile except `compact`, the size setting's code default SHALL be derived from the active JetStream profile; `compact` SHALL be exempt from this pipeline-specific default.
Each block of a stream whose records feed alert evaluation SHALL be consumed by one EventWriter replica at a time, through that block's own durable, under a fenced lease. A change SHALL move blocks between streams online with the candidate-stream move protocol, so that a source's records keep their order and no record is lost.

#### Scenario: A log burst does not consume the events buffer
- **GIVEN** a synthetic log burst that fills the logs stream
- **WHEN** events continue to arrive
- **THEN** the events stream SHALL keep accepting them

#### Scenario: Splitting the logs stream keeps a source's order
- **GIVEN** one logs stream receiving records from `host000123.example.com`
- **WHEN** the logs stream count is raised from one to four
- **THEN** that host's records SHALL be stored and routed in publish order
- **AND** no record SHALL be lost or terminated

### Requirement: Accepted telemetry is never evicted unprocessed
A telemetry stream whose records are stored or alert-evaluated by EventWriter SHALL use DiscardNew, so a full stream refuses new publishes instead of deleting accepted messages that no consumer has processed.
Publishers SHALL report every refusal, and a collector receiving a protocol that cannot be retransmitted SHALL count refused and dropped records in health.

#### Scenario: A full logs stream refuses at the collector
- **GIVEN** the logs stream at its size limit because EventWriter is stopped
- **WHEN** a collector publishes a log batch
- **THEN** the publish SHALL be refused
- **AND** every message already in the stream SHALL remain
- **AND** the collector SHALL spool or count the refused records

### Requirement: Transient failures never terminate a delivery
EventWriter durables whose records feed stored telemetry or alert evaluation SHALL NOT terminate a message because of a transient failure such as an unavailable store, a failed warehouse load or a refused candidate publish.
Only a failure classified as permanent, such as an undecodable payload, SHALL be copied to the telemetry dead-letter stream, and the source message SHALL be terminated only after that copy is acknowledged.

#### Scenario: A store outage outlasts five deliveries
- **GIVEN** the warehouse is unavailable for longer than five redelivery intervals
- **WHEN** it recovers
- **THEN** every affected message SHALL be stored and evaluated
- **AND** no message SHALL have reached a terminal delivery

### Requirement: Warehouse loads are coalesced
EventWriter SHALL coalesce rows for each warehouse dataset across batches and flush them as a load when a row, byte or age limit is reached, and SHALL acknowledge the contributing source messages only after that load succeeds.

#### Scenario: Small batches become one load
- **GIVEN** 300 consecutive 100-row log batches arriving within the age limit
- **WHEN** the coalescer flushes
- **THEN** the rows SHALL be written in loads bounded by the row and byte limits rather than in 300 loads

### Requirement: Storage and routing complete before acknowledgement
EventWriter SHALL acknowledge a source message only after its records are stored and every alert candidate derived from it has a publish acknowledgement; the two MAY proceed concurrently.

#### Scenario: Routing finishes before the warehouse load
- **WHEN** a candidate publish succeeds while the coalesced load is still pending
- **THEN** the source message SHALL remain unacknowledged until the load succeeds

### Requirement: Collectors batch and pipeline publishes
Log and trap collectors SHALL pack multiple records of one block subject per JetStream message, in source order, up to a record, byte or time limit, only once the old `events` stream no longer binds their subjects, and SHALL publish one record per message until then and SHALL keep a bounded number of publishes awaiting acknowledgement, so collector throughput does not depend on one round trip per record.

#### Scenario: Collector throughput is not round-trip bound
- **GIVEN** a synthetic syslog source sending 20,000 records per second to one collector
- **WHEN** the collector publishes to JetStream with a 1 ms round trip
- **THEN** it SHALL publish all records without spooling

### Requirement: Single-writer processors scale by key partition
Processors whose correctness requires one writer per key SHALL take that ownership through fenced leases on blocks of the shared block layout, rather than by running only on the cluster coordinator.

#### Scenario: Lifecycle transitions keep series order across replicas
- **GIVEN** anomaly lifecycle transitions for one synthetic series processed while three core replicas run
- **WHEN** the series opens and then clears
- **THEN** its transitions SHALL be stored and evaluated in that order
- **AND** other series SHALL be processed on other replicas concurrently
