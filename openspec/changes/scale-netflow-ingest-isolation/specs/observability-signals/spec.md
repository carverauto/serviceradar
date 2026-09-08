## ADDED Requirements

### Requirement: Dedicated EventWriter demand domain for raw flows
The EventWriter subsystem SHALL consume raw flow subjects (`flows.raw.netflow`, `flows.raw.sflow`, and other configured raw flow subjects on the flows stream) through a Broadway pipeline whose GenStage demand is independent of non-flow telemetry (logs, metrics, Falco, OTEL). A single producer process SHALL NOT fair-share demand across flow durables and unrelated durables such that NetFlow pull budget is diluted by other signal types.

#### Scenario: Flow demand is independent of log demand
- **WHEN** the logs EventWriter path has zero or low GenStage demand because log processing is slow
- **THEN** the flow EventWriter path SHALL continue to request JetStream messages according to its own demand
- **AND** flow pull requests SHALL NOT be reduced solely because non-flow consumers exist in another pipeline

#### Scenario: Flow pipeline registers only flow consumers
- **WHEN** the flow EventWriter pipeline starts
- **THEN** it SHALL create durable pull consumers only for configured flow subjects on the flows stream
- **AND** it SHALL NOT register durables for `logs.>`, `falco.logs`, or `otel.*` subjects

### Requirement: Demand-coupled long-poll JetStream pulls for flows
The flow EventWriter producer SHALL request JetStream messages only when Broadway/GenStage demand and local in-flight capacity allow. Pull batch size SHALL be derived from remaining demand and a configured per-consumer pull batch cap. The primary pull mode for flows SHALL use an expires-based long-poll rather than relying on continuous `no_wait` empty pulls driven by a fixed sub-second timer.

#### Scenario: Pull batch respects demand
- **WHEN** the flow producer has demand D and pull batch cap B
- **THEN** it SHALL request at most `min(D, B, remaining_buffer_budget)` messages in the next pull
- **AND** when D is zero it SHALL NOT issue new flow pulls

#### Scenario: Long-poll instead of empty no_wait churn
- **WHEN** demand is positive and the flows stream temporarily has no new messages
- **THEN** the producer SHALL wait on an expires-based pull up to the configured expire window
- **AND** it SHALL NOT depend on a 100ms busy poll of `no_wait` pulls as the primary fetch mechanism

#### Scenario: Backpressure releases via ack
- **WHEN** flow messages are successfully persisted
- **THEN** the pipeline SHALL ack JetStream messages
- **AND** acking SHALL free `max_ack_pending` capacity so subsequent demand-driven pulls can proceed

### Requirement: Flow-specific consumer flow-control defaults
The flow EventWriter consumers SHALL use flow-tuned defaults for `consumer_pull_batch_size` and `max_ack_pending` that are high enough to avoid pull round-trip thrash under sustained NetFlow rates, while remaining bounded so a single BEAM process cannot retain unbounded unacked payloads. Defaults SHALL be overridable via configuration/environment.

#### Scenario: Defaults exceed historical thrash floor
- **WHEN** EventWriter starts with default flow consumer settings
- **THEN** `consumer_pull_batch_size` for netflow SHALL be at least 64
- **AND** `max_ack_pending` for the flow path SHALL be independently configurable from the global metrics/logs defaults

### Requirement: Single database writer for flow rows after stream cutover
After migration to the dedicated flows stream, exactly one EventWriter path SHALL persist a given raw flow message into `platform.ocsf_network_activity`. The system SHALL NOT dual-insert the same JetStream message from both the shared `events` filter consumer and the flows stream consumer.

#### Scenario: Cutover does not double-write
- **WHEN** publishers have switched to the flows stream and the migration drain of `events` flow durables is complete
- **THEN** only the flow EventWriter pipeline SHALL insert new raw NetFlow rows
- **AND** the shared EventWriter pipeline SHALL NOT continue consuming `flows.raw.*` from `events`

#### Scenario: Migration dual-consume window
- **WHEN** operators run the dual-consume migration window
- **THEN** the system MAY consume residual `flows.raw.*` messages still present on `events` while also consuming the new flows stream
- **AND** publish cutover SHALL ensure a given message exists on only one stream so CNPG inserts remain single-writer per message

### Requirement: Flow ingest lag and retention risk observability
The system SHALL expose telemetry for the flow EventWriter path that includes JetStream consumer pending depth, ack-pending depth, pull request sizing relative to demand, overflow/NAK counts, and a retention-risk signal when backlog threatens configured stream MaxAge or MaxBytes. Operators SHALL be able to detect flow lag before the NetFlow UI last-15-minute window goes empty.

#### Scenario: Pending backlog is visible
- **WHEN** the flow durable has `num_pending` greater than zero for a sustained interval
- **THEN** EventWriter flow telemetry SHALL report pending and ack-pending gauges or equivalent metrics
- **AND** a retention-risk indicator SHALL elevate when backlog coexists with high stream age or byte utilization

#### Scenario: Demand and pull sizing are visible
- **WHEN** the flow producer issues a JetStream pull
- **THEN** telemetry SHALL record the requested batch size and the demand budget that produced it

### Requirement: Flow path lag SLO relative to UI windows
Under sustained export load within documented capacity, the flow EventWriter path SHALL keep database flow freshness lag well below the primary NetFlow map time window (default 15 minutes) so operators do not observe an empty map while the collector is actively converting flows. When load exceeds capacity, the system SHALL prefer explicit lag/retention-risk signals and discard-old at the stream boundary over unbounded BEAM memory growth.

#### Scenario: Healthy path keeps map window populated
- **WHEN** exporters continuously send NetFlow within the sized capacity envelope
- **AND** EventWriter and CNPG are healthy
- **THEN** `max(time)` on `platform.ocsf_network_activity` SHALL remain within a lag well under 15 minutes of wall clock
- **AND** a last-15-minute NetFlow map query SHALL return non-zero flow records

#### Scenario: Overload stays bounded
- **WHEN** flow publish rate exceeds EventWriter processing rate
- **THEN** the producer SHALL apply demand and `max_ack_pending` bounds rather than growing an unbounded in-process queue
- **AND** JetStream discard-old on the flows stream SHALL be the durability overflow valve once MaxBytes/MaxAge are hit
