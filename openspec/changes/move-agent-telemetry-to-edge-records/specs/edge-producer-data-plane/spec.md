## ADDED Requirements

### Requirement: Durable agent telemetry is delivered as edge records
The agent SHALL deliver every durable data family it produces, other than live media streams, as
edge records through the agent spool and the edge-record ingest service. Control traffic and
ephemeral latest-wins status summaries SHALL remain on the agent-gateway status and control
interfaces.

#### Scenario: A migrated producer survives a failed send
- **GIVEN** a migrated producer whose agent holds that producer's contract grant
- **WHEN** the producer emits a batch and the gateway is unreachable
- **THEN** the batch is committed to the agent spool before the producer is told it was accepted
- **AND** it is delivered when the gateway returns, with no loss and no duplicate domain rows

#### Scenario: Live media stays off the record pipeline
- **WHEN** an agent relays an RTSP camera stream
- **THEN** the stream does not enter the agent spool

### Requirement: Each data family and scheduling model has one typed output contract
Each pair of data family and scheduling model SHALL have exactly one typed output contract in the
signed contract registry. A producer that emits JSON today SHALL be given a typed batch message
before it migrates. The registry SHALL NOT admit a contract whose payload is an untyped status
envelope. Every agent-scheduled `MetricBatch` SHALL use `serviceradar.metrics.batch` and SHALL
carry no source authorization. That includes sysmon, SNMP, ICMP, rperf, MTR metrics, the
status-interval sweep summary, and the whole `MetricBatch` appended to each unleased
sweep-results chunk. The status-interval summary SHALL remain the single newest-group sample it
is today. The agent SHALL NOT add a per-group status-interval emitter.

#### Scenario: Agent-scheduled metrics share one contract
- **WHEN** sysmon, SNMP, ICMP, rperf, or MTR emits a `MetricBatch` edge record
- **THEN** the record names `serviceradar.metrics.batch`
- **AND** the record carries no source authorization

#### Scenario: The sweep summary stays the newest-group status sample
- **WHEN** the agent emits its periodic sweep summary for the newest group, leased or not
- **THEN** the record names `serviceradar.metrics.batch`
- **AND** the record carries no source authorization
- **AND** the agent does not emit a status-interval sample for each other group

#### Scenario: An untyped envelope is refused
- **WHEN** a record names a contract whose payload is a raw status chunk
- **THEN** the gateway rejects it permanently as an unknown contract

### Requirement: Agent-scheduled producers emit under standing output grants
A producer that runs on the agent's own schedule from the config core delivered SHALL emit records
only under a standing output grant: a production capability that core signs per agent, contract
and authority epoch and delivers in the agent config. Such records SHALL carry no source
authorization. Core SHALL issue a grant only while the contract is active in the installation
registry and the agent's operator switch is on, and SHALL revoke it by moving its epoch when the
switch is turned off.

#### Scenario: Revoking a grant stops new authoritative output
- **GIVEN** an agent holding a standing grant for a contract
- **WHEN** an operator turns the agent's switch off
- **THEN** core moves the grant's authority epoch
- **AND** later records under the old epoch are not projected

#### Scenario: An unleased sweep emits under a standing grant
- **GIVEN** a sweep group with a `target_query` that core does not lease
- **WHEN** the agent runs it from its config
- **THEN** its results are delivered as edge records under the agent's sweep results grant
- **AND** they are projected into the same sweep and inventory tables as today
- **AND** the whole `MetricBatch` appended to each of those results chunks is delivered with
  those results, under `serviceradar.metrics.batch` with no source authorization

### Requirement: Core-scheduled sweeps keep their sweep leases
A sweep execution that core leases SHALL keep its signed plan and its
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP` source authorization. The sweep lease delivery
SHALL keep its single production capability naming `serviceradar.sweep.observation` and SHALL NOT
gain a second capability. That execution SHALL NOT emit a separate metric batch. Core already
stores the execution through the sweep projection.

#### Scenario: A leased execution emits no metric batch
- **WHEN** a leased static sweep execution completes
- **THEN** the agent emits no `MetricBatch` for that execution
- **AND** the group's periodic sweep summary still uses `serviceradar.metrics.batch`
- **AND** the execution's results remain available from the sweep projection

#### Scenario: The lease delivery keeps one production capability
- **WHEN** core delivers a sweep lease for a leased static sweep
- **THEN** the delivery carries one signed capability, for `serviceradar.sweep.observation`

### Requirement: Migrated producers append through one durable sink
Every migrated producer SHALL append through the agent producer sink, which validates the
producer's grant, assigns event identity, commits the record to the spool, and acknowledges the
producer only after the commit is durable. A refused admission SHALL be returned to the producer
as retryable backpressure, and a producer that drops a batch SHALL count the drop with its reason.

#### Scenario: A full spool pushes back instead of dropping silently
- **WHEN** the spool is at its admission ceiling and a producer appends
- **THEN** the producer receives a retryable refusal
- **AND** any batch it then discards is counted with a reason

### Requirement: Edge-record streams are replicated
The edge-record stream, and every stream a projector publishes migrated data to, SHALL be
replicated across the NATS cluster, and stream reconciliation SHALL raise the replica count of an
existing stream to the configured value.

#### Scenario: Losing one NATS node loses no acknowledged record
- **GIVEN** a three-node NATS cluster
- **WHEN** the node holding a stream leader fails after the agent reclaimed an acknowledged record
- **THEN** the record is still delivered to its projector

### Requirement: Each producer emits on one path and legacy is removed at cutover
A producer SHALL emit on exactly one of the legacy status path or the edge-record path. It SHALL
stop its status-path emission only in the release where that producer emits as edge records and
while the agent holds that contract's grant. A producer that has not yet migrated SHALL keep the
status path even when the agent holds the grant. The legacy agent emissions and the gateway
publishers that serve them SHALL be removed in one cutover release, after every family has passed
a parity soak against a control agent. No durable agent data SHALL remain on `StreamStatus` or
`PushStatus` after it.

#### Scenario: A migrated producer holding its grant stops its legacy emission
- **GIVEN** an agent holding the `serviceradar.metrics.batch` grant
- **AND** sysmon emits as edge records in this release
- **WHEN** it collects sysmon metrics
- **THEN** it emits them only as edge records and not through `StreamStatus`

#### Scenario: A producer not yet migrated keeps the status path
- **GIVEN** an agent holding the `serviceradar.metrics.batch` grant because sysmon has migrated
- **AND** SNMP, ICMP, rperf, MTR, and the periodic sweep summary have not yet moved
- **WHEN** the agent collects one of those metrics
- **THEN** it still emits that producer's batch through `StreamStatus`

#### Scenario: An unleased results chunk moves its whole metric batch
- **GIVEN** an unleased sweep whose results chunk carries a `MetricBatch`
- **WHEN** that sweep's results move onto the unleased sweep results contract
- **THEN** that whole batch moves in the same release onto `serviceradar.metrics.batch`
- **AND** it keeps every series it carries, including `sweep.total_hosts`,
  `sweep.available_hosts`, `sweep.sequence`, `sweep.port.*`, `sweep.host.*`,
  `sweep.scanner.*`, and `sweep.banner_grab.*`
- **AND** until that release the batch stays on the results push
