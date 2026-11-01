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
metric batches and banner results a sweep lease produces, SHALL keep
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP` under the existing sweep lease.
Traces from a sweep whose modes include mtr SHALL be `MtrTraceBatchV1` under
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`.

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

### Requirement: Query-resolved sweeps freeze the compiler scan set
At lease time core SHALL freeze the scan set the sweep compiler scans today and
SHALL sign that set as the scheduled plan for the execution, under the existing
sweep lease and `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`. The scan set is
the query's hosts, the alias addresses of those devices, and the group's static
targets. A set that exceeds the plan builder's limits SHALL be split across
executions or ranges so every member is in a signed plan. The group's sweep
results and sweep metric batch SHALL be emitted together under that lease. A
failed device read SHALL keep the last signed plan and SHALL NOT sign an empty
plan. When no signed plan exists yet, the group waits for a successful read. An
unparseable query SHALL contribute no hosts, and the group's static targets
SHALL still run.

#### Scenario: The signed plan is the compiler scan set
- **GIVEN** a sweep group whose `target_query` matches 10.0.0.5, whose matched
  device has alias 10.0.0.9, and whose static targets include 10.1.1.1
- **WHEN** core freezes the plan for an execution
- **THEN** the signed plan contains 10.0.0.5, 10.0.0.9, and 10.1.1.1

#### Scenario: A large scan set is split
- **WHEN** the scan set exceeds the plan builder's limits
- **THEN** core splits it across executions or ranges
- **AND** every member is included in a signed sweep plan under
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
- **AND** the group's sweep results and sweep metric batch are both edge records

#### Scenario: A failed device read keeps the last plan
- **GIVEN** a sweep group with a signed plan from the previous resolution
- **WHEN** the device read for its `target_query` fails
- **THEN** core keeps that signed plan
- **AND** it does not sign an empty plan

#### Scenario: An unparseable query leaves static targets
- **GIVEN** a sweep group with static target 10.1.1.1 and a `target_query` that
  cannot be parsed
- **WHEN** core resolves the group
- **THEN** the query contributes no hosts
- **AND** the signed plan contains 10.1.1.1

### Requirement: Sweep groups the lease skipped get a home before cutover
Before legacy status-path emission is removed, core SHALL lease every runnable
sweep group.

The lease schedule minimum SHALL be 1 second. A whole-second interval, and a
cron whose closest fires are at least one second apart, SHALL be leased. A
schedule denser than one second SHALL be refused at configuration with an
operator-visible validation error.

A sweep group whose modes include mtr SHALL be leased. Its reachability and port
results SHALL carry `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`. Its traces
SHALL be `MtrTraceBatchV1` under `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`.
The group SHALL NOT be refused for mtr mode.

Banner results SHALL use a new typed banner-results batch and its own output
contract in the signed registry. `EdgeRecordV1` and the frozen payloads SHALL
stay unchanged. Banner results for an execution SHALL carry that execution's
sweep lease and `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`.

#### Scenario: A one-minute sweep is leased
- **WHEN** a sweep group runs on a 60 second interval
- **THEN** core signs a sweep lease for it

#### Scenario: An mtr-mode sweep splits traces from reachability
- **WHEN** a sweep group's modes include mtr
- **THEN** its reachability and port results carry
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
- **AND** its traces are `MtrTraceBatchV1` records under
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`
- **AND** the group is not refused for mtr mode

#### Scenario: Banner results use the sweep lease
- **WHEN** a leased sweep execution grabs banners
- **THEN** the banner results are records on the banner-results contract
- **AND** they carry that execution's
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
- **AND** `EdgeRecordV1` is unchanged

### Requirement: Unrepresentable sweep targets are refused at configuration
After short intervals, mtr mode, and banner results have a home, the plan
builder SHALL refuse a sweep group it still cannot represent, including a static
or resolved IPv6 prefix wider than /65 (`:target_too_wide`) and a schedule
denser than one second, when the sweep group is configured. The refusal SHALL be
an operator-visible validation error. An existing group of that kind SHALL be
reported as not runnable. That group SHALL NOT emit on the legacy status path
and SHALL NOT emit edge records.

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
legacy status path or the edge-record path. A sweep group's results, its sweep
metric batch, and its banner results are one producer for this rule until that
group has a signed sweep lease: they SHALL stay on the legacy path together,
and SHALL move to edge records together under that lease. Traces from a group
whose modes include mtr SHALL move with that lease onto the MTR check lease.
Per-family parity soaks
SHALL finish before cutover. The next release SHALL remove legacy agent
status-path emission and the gateway's matching publishers together, and only
after every runnable sweep group has a signed sweep lease. After that release,
no durable agent data remains on `StreamStatus` or `PushStatus`.

#### Scenario: An opted-in agent stops the legacy emission
- **GIVEN** an agent opted in for the metrics batch contract
- **WHEN** it collects sysmon metrics
- **THEN** it emits them only as edge records and not through `StreamStatus`

#### Scenario: An unleashed sweep stays paired
- **GIVEN** an agent opted in for the metrics batch contract
- **AND** a sweep group with no signed sweep lease yet
- **WHEN** that group produces sweep results, a sweep metric batch, and banner
  results
- **THEN** all three are emitted on the legacy status path
- **AND** after the group has a signed sweep lease, the results, the metric
  batch, and the banner results are edge records under
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
