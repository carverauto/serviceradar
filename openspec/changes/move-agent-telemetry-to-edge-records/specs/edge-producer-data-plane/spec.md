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
MTR checks, ICMP checks, SNMP polls, plugin runs and mapper jobs SHALL emit
records only under a check lease that core signed: a production capability for
the lease and, per execution, a source authorization of kind
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`. Integration sync runs SHALL emit
under that same check-lease machinery with a source authorization of kind
`EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN`. Check leases SHALL reuse the
sweep lease epoch fence and missed-run marking. Sweep executions, including the
metric batches a sweep lease produces, SHALL keep
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP` under the existing sweep lease.

#### Scenario: A scheduled MTR check is authorized per execution
- **WHEN** core schedules an MTR check for an agent
- **THEN** the agent's MTR trace records carry the execution's signed scheduled-check
  source authorization
- **AND** a record whose lease epoch is stale is refused unless it carries a
  delivery grant

#### Scenario: A leased sweep keeps the sweep source kind
- **WHEN** an agent emits the sweep results and the metric batch for one sweep
  lease execution, including a `target_query` group whose lease exists
- **THEN** both carry `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
- **AND** neither carries `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`

### Requirement: Query-resolved sweeps freeze host addresses under the sweep lease
Core SHALL resolve a sweep group's `target_query` at lease time to individual
host addresses and SHALL freeze that set into a signed scheduled plan for the
execution, under the existing sweep lease and
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`. Host addresses are representable
by the plan builder. A resolved set that exceeds the plan builder's limits SHALL
be split across executions or ranges so every host is in a signed plan. The
group's sweep results and sweep metric batch SHALL be emitted together under
that lease.

#### Scenario: A large resolved host set is split
- **WHEN** the host set resolved from a `target_query` exceeds the plan builder's
  limits
- **THEN** core splits it across executions or ranges
- **AND** every host is included in a signed sweep plan under
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
- **AND** the group's sweep results and sweep metric batch are both edge records

### Requirement: Unrepresentable sweep targets are refused at configuration
The plan builder SHALL refuse a sweep target it cannot represent, including a
static or resolved IPv6 prefix wider than /65 (`:target_too_wide`), when the
sweep group is configured. The refusal SHALL be an operator-visible validation
error. An existing group with such a target SHALL be reported as not runnable.
That group SHALL NOT emit on the legacy status path and SHALL NOT emit edge
records.

#### Scenario: A prefix wider than /65 is refused
- **WHEN** an operator saves a sweep group whose target is an IPv6 prefix wider
  than /65
- **THEN** configuration returns an operator-visible validation error
- **AND** the group does not run on the legacy status path

#### Scenario: An existing unrepresentable group does not run
- **GIVEN** a sweep group already stored with an IPv6 prefix wider than /65
- **WHEN** core evaluates that group
- **THEN** the group is reported as not runnable
- **AND** it emits neither legacy status nor edge records

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
For a given agent and producer, the agent SHALL emit on exactly one of the
legacy status path or the edge-record path. A `target_query` sweep group's
results and its sweep metric batch are one producer for this rule: they SHALL
stay on the legacy path together until that group has a signed sweep lease, and
SHALL move to edge records together under that lease. Per-family parity soaks
SHALL finish before cutover. The next release SHALL remove legacy agent
status-path emission and the gateway's matching publishers together, and only
after every runnable sweep group has a signed sweep lease. After that release,
no durable agent data remains on `StreamStatus` or `PushStatus`.

#### Scenario: An opted-in agent stops the legacy emission
- **GIVEN** an agent opted in for the metrics batch contract
- **WHEN** it collects sysmon metrics
- **THEN** it emits them only as edge records and not through `StreamStatus`

#### Scenario: Query-resolved sweep output stays paired
- **GIVEN** an agent opted in for the metrics batch contract
- **AND** a `target_query` sweep group with no signed sweep lease yet
- **WHEN** that group produces sweep results and a sweep metric batch
- **THEN** both are emitted on the legacy status path
- **AND** after the group has a signed sweep lease, both are edge records under
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
