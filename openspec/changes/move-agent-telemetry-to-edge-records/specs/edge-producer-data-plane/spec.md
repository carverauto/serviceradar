## ADDED Requirements

### Requirement: Durable agent telemetry is delivered as edge records
The agent SHALL deliver every durable data family it produces, other than live
media streams, as edge records through the agent spool and the edge-record ingest
service. Control traffic and ephemeral latest-wins status summaries SHALL remain
on the agent-gateway status and control interfaces.

#### Scenario: A migrated producer survives a failed send
- **GIVEN** an agent opted in for a migrated data family
- **WHEN** the producer emits a batch and the gateway is unreachable
- **THEN** the batch is committed to the agent spool before the producer is told
  it was accepted
- **AND** it is delivered when the gateway returns, with no loss and no duplicate
  domain rows

#### Scenario: Live media stays off the record pipeline
- **WHEN** an agent relays an RTSP camera stream
- **THEN** the stream does not enter the agent spool

### Requirement: Each data family has one typed output contract
Each migrated data family SHALL have exactly one output contract in the signed
contract registry, whose payload is a typed protobuf message. A producer that
emits JSON today SHALL be given a typed batch message before it migrates. The
registry SHALL NOT admit a contract whose payload is an untyped status envelope.

#### Scenario: Metric producers share one contract
- **WHEN** sysmon, SNMP and ICMP producers on one agent emit metrics
- **THEN** each emits `metric.v1.MetricBatch` records under the same metrics batch
  contract, distinguished by the batch's producer kind

#### Scenario: An untyped envelope is refused
- **WHEN** a record names a contract whose payload is a raw status chunk
- **THEN** the gateway rejects it permanently as an unknown contract

### Requirement: Scheduled producers run under core-signed check leases
A producer whose work core schedules SHALL emit records only under a check lease
that core signed: a production capability for the lease and, per execution, a
source authorization of kind `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`, or
`EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN` for integration sync runs. Check
leases SHALL reuse the sweep lease epoch fence and missed-run marking.

#### Scenario: A scheduled MTR check is authorized per execution
- **WHEN** core schedules an MTR check for an agent
- **THEN** the agent's MTR trace records carry the execution's signed scheduled-check
  source authorization
- **AND** a record whose lease epoch is stale is refused unless it carries a
  delivery grant

### Requirement: Passive producers run under standing output grants
A producer that core does not schedule SHALL emit records only under a standing
output grant: a production capability that core signs per agent, contract and
authority epoch, with a bounded validity window, renewed while the agent is
enrolled and the contract is enabled. Such records SHALL carry no source
authorization, and the contract's payload rules SHALL state that.

#### Scenario: Revoking a grant stops new authoritative output
- **GIVEN** an agent holding a standing grant for a passive contract
- **WHEN** an operator disables that contract for the agent
- **THEN** core bumps the grant's authority epoch
- **AND** later records under the old epoch are not published as primary

### Requirement: Migrated producers append through one durable sink
Every migrated producer SHALL append through the agent producer sink, which
validates the producer's grant, assigns event identity, commits the record to the
spool, and acknowledges the producer only after the commit is durable. A refused
admission SHALL be returned to the producer as retryable backpressure, and a
producer that drops a batch SHALL count the drop with its reason.

#### Scenario: A full spool pushes back instead of dropping silently
- **WHEN** the spool is at its admission ceiling and a producer appends
- **THEN** the producer receives a retryable refusal
- **AND** any batch it then discards is counted with a reason

### Requirement: Each family emits on one path at a time
For a given agent and data family, the agent SHALL emit on exactly one of the
legacy status path or the edge-record path. The legacy emission SHALL be removed
only in a separately gated release after a parity soak shows equal row counts and
values against a control agent.

#### Scenario: An opted-in agent stops the legacy emission
- **GIVEN** an agent opted in for the metrics batch contract
- **WHEN** it collects sysmon metrics
- **THEN** it emits them only as edge records and not through `StreamStatus`
