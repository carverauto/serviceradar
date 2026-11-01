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
envelope. Every agent-scheduled `MetricBatch`, including metrics of an unleased sweep, uses
`serviceradar.metrics.batch` and carries no source authorization. Only a leased sweep's metric
batch uses `serviceradar.metrics.scheduled`.

#### Scenario: Agent-scheduled metrics share one contract
- **WHEN** sysmon, SNMP, ICMP, rperf, MTR, or an unleased sweep emits a `MetricBatch` edge record
- **THEN** the record names `serviceradar.metrics.batch`
- **AND** the record carries no source authorization

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
- **AND** the metric batch that rides that same status push is delivered with those results,
  under `serviceradar.metrics.batch` with no source authorization

### Requirement: Core-scheduled sweeps keep their sweep leases
A sweep execution that core leases SHALL keep its signed plan and its
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP` source authorization. The sweep lease delivery
SHALL sign and carry a production capability naming `serviceradar.sweep.observation` and a second
production capability naming `serviceradar.metrics.scheduled`. The metric batch of that execution
SHALL name `serviceradar.metrics.scheduled`, SHALL be authorized by that second capability, and
SHALL carry the same `SCHEDULED_SWEEP` source authorization.

#### Scenario: A leased sweep's metrics carry its authorization
- **WHEN** a leased static sweep execution emits its metric batch
- **THEN** the record names `serviceradar.metrics.scheduled`
- **AND** its production capability names `serviceradar.metrics.scheduled`
- **AND** it carries the execution's `SCHEDULED_SWEEP` source authorization

#### Scenario: The lease delivery carries both production capabilities
- **WHEN** core delivers a sweep lease for a leased static sweep
- **THEN** the delivery carries a signed capability for `serviceradar.sweep.observation`
- **AND** a second signed capability for `serviceradar.metrics.scheduled`

### Requirement: Migrated producers append through one durable sink
Every migrated producer SHALL append through the agent producer sink, which validates the
capability that authorizes that record (its standing grant, or the leased sweep's metrics
production capability), assigns event identity, commits the record to the spool, and acknowledges
the producer only after the commit is durable. A refused admission SHALL be returned to the
producer as retryable backpressure, and a producer that drops a batch SHALL count the drop with
its reason.

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
- **AND** SNMP, ICMP, rperf and MTR metrics have not yet moved to edge records
- **WHEN** the agent collects one of those metrics
- **THEN** it still emits that producer's batch through `StreamStatus`

#### Scenario: Unleased sweep metrics leave the status push with the results
- **GIVEN** an unleased sweep whose `MetricBatch` rides the sweep-results status push
- **WHEN** that sweep's results move onto the unleased sweep results contract
- **THEN** its metric batch moves in the same release onto `serviceradar.metrics.batch`
- **AND** until that release the metric batch stays on the status push
