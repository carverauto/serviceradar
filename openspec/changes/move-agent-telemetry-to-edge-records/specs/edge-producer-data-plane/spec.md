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

### Requirement: Each data family has one typed output contract per authorization rule
Each migrated data family SHALL have one output contract in the signed contract
registry for each source-authorization rule it uses. The payload SHALL be a typed
protobuf message. A producer that emits JSON today SHALL be given a typed batch
message before it migrates. The registry SHALL NOT admit a contract whose payload
is an untyped status envelope. Each contract's payload rules SHALL state that
contract's source-authorization rule.

Metrics SHALL use two contracts that share the `metric.v1.MetricBatch` payload,
one projector, and the existing metrics destination.
`serviceradar.metrics.batch` v1 SHALL be the passive metrics contract: a standing
grant, and its payload rules SHALL state that records carry no source
authorization. Sysmon, and any other passive metric producer, SHALL use it.
`serviceradar.metrics.scheduled` v1 SHALL be the lease-run metrics contract. Its
payload rules SHALL require a source authorization: `SCHEDULED_CHECK` for SNMP,
ICMP, and MTR metrics and for rperf, and `SCHEDULED_SWEEP` for a sweep metric
batch under the sweep lease.

#### Scenario: Passive and lease-run metrics use different contracts
- **WHEN** sysmon and an SNMP poll on one agent emit metrics
- **THEN** sysmon emits `metric.v1.MetricBatch` under `serviceradar.metrics.batch`
  v1 with no source authorization
- **AND** the SNMP metrics emit `metric.v1.MetricBatch` under
  `serviceradar.metrics.scheduled` v1 with
  `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK`

#### Scenario: A sweep metric batch uses the lease-run contract
- **WHEN** a leased sweep emits its metric batch
- **THEN** the batch is `metric.v1.MetricBatch` under
  `serviceradar.metrics.scheduled` v1
- **AND** it carries `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`

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
`EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK` when MTR checks move, with no
dependency on that group's sweep lease.

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
The signed plan for a sweep execution SHALL be the targets returned by
`SweepCompiler`'s target resolution for that group, the same function the
compiler uses today, not a second resolver, and SHALL be signed under the
existing sweep lease and `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`.
That function scopes the query with `normalize_target_query`.
`SRQLQuery.ensure_target/2` prepends `in:devices` only when the trimmed query
does not already start with `in:`. An existing `in:` target is left unchanged.
It appends `partition:<group partition>` unless the query already names
partition. It keeps an alias only when the value is a strict IP,
`alias_type` is ip, the state is confirmed, updated, or detected, `last_seen`
is inside the AliasRecency window, the address is not already a primary, and
the count for that device is within `sweep_max_alias_targets_per_device`. A
non-address value, including a CIDR in the ip column, is dropped for that row
and SHALL NOT be planned as a prefix. The group's static targets are included.
A set that exceeds the plan builder's limits SHALL be split across executions
or ranges so every member is in a signed plan. The group's sweep results and
sweep metric batch SHALL be emitted together under that lease. A successful
read whose targets differ from the last signed plan SHALL cause a re-plan. A
failed device read, including a later page error or an alias-table error, SHALL
keep the last signed plan, SHALL NOT sign the pages already fetched, and SHALL
NOT sign a plan that omits aliases. When no signed plan exists yet, the group
waits for a successful read. An unparseable query, and a query that parses but
cannot be translated or cast, SHALL contribute no hosts and SHALL NOT keep the
last plan, and the group's static targets SHALL still run.

#### Scenario: The signed plan is the compiler scan set
- **GIVEN** a sweep group whose `target_query` matches 10.0.0.5, whose matched
  device has alias 10.0.0.9, and whose static targets include 10.1.1.1
- **WHEN** core freezes the plan for an execution
- **THEN** the signed plan contains 10.0.0.5, 10.0.0.9, and 10.1.1.1
- **AND** it contains no other address

#### Scenario: Resolution is scoped to the group partition
- **GIVEN** a sweep group in partition tenant-a whose `target_query` is
  `ip = '10.0.0.5'` and does not name a partition
- **AND** a device 10.0.0.5 exists in partition tenant-b
- **WHEN** core freezes the plan
- **THEN** the resolution query is scoped to partition tenant-a
- **AND** the signed plan does not contain the tenant-b device

#### Scenario: An existing in: target is left unchanged
- **GIVEN** a sweep group whose `target_query` is `in:services ip = '10.0.0.5'`
- **WHEN** core resolves that query
- **THEN** the query keeps the `in:services` target

#### Scenario: Alias targets stay inside the compiler cap
- **GIVEN** a device whose alias rows pass the compiler's alias filters and
  exceed `sweep_max_alias_targets_per_device`
- **WHEN** core freezes the plan
- **THEN** the plan includes at most that cap of the device's alias addresses

#### Scenario: A CIDR in the ip column is dropped for that row
- **GIVEN** a query row whose ip is `10.0.0.0/24` and a static target 10.1.1.1
- **WHEN** core freezes the plan
- **THEN** the plan does not contain `10.0.0.0/24`
- **AND** the plan contains 10.1.1.1

#### Scenario: A large scan set is split
- **WHEN** the scan set exceeds the plan builder's limits
- **THEN** core splits it across executions or ranges
- **AND** every member returned by `SweepCompiler` target resolution is included
  in a signed sweep plan under `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`
- **AND** the group's sweep results and sweep metric batch are both edge records

#### Scenario: A failed device read keeps the last plan
- **GIVEN** a sweep group with a signed plan from the previous resolution
- **WHEN** a later page of the device read fails, or the alias-table read fails
- **THEN** core keeps that signed plan
- **AND** it does not sign the pages already fetched
- **AND** it does not sign a plan that omits aliases

#### Scenario: An unparseable query leaves static targets
- **GIVEN** a sweep group with static target 10.1.1.1 and a `target_query` that
  cannot be parsed
- **WHEN** core resolves the group
- **THEN** the query contributes no hosts
- **AND** the signed plan contains 10.1.1.1

#### Scenario: A query that cannot be translated drops query hosts
- **GIVEN** the last signed plan contains 10.0.0.5 and static target 10.1.1.1
- **WHEN** the group's query parses but cannot be translated or cast
- **THEN** the signed plan contains 10.1.1.1
- **AND** it does not contain 10.0.0.5

#### Scenario: A changed read replaces the signed set
- **GIVEN** the last signed plan contains 10.0.0.5
- **WHEN** a successful read matches only 10.0.0.6
- **THEN** the next signed plan contains 10.0.0.6
- **AND** it does not contain 10.0.0.5

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
target that is an IPv6 prefix wider than /65 (`:target_too_wide`) and a schedule
denser than one second, when the sweep group is configured. The refusal SHALL be
an operator-visible validation error. An existing group of that kind SHALL be
reported as not runnable. That group SHALL NOT emit on the legacy status path
and SHALL NOT emit edge records. `SweepCompiler` mode handling SHALL NOT refuse
the group: TCP modes with no ports are dropped, modes outside icmp, tcp,
tcp_connect, and mtr are dropped, and the remaining modes still run. A CIDR
dropped from a query row SHALL NOT refuse the group.

#### Scenario: A prefix wider than /65 is refused
- **WHEN** an operator saves a sweep group whose static target is an IPv6 prefix
  wider than /65
- **THEN** configuration returns an operator-visible validation error
- **AND** the group does not run on the legacy status path

#### Scenario: An existing unrepresentable group does not run
- **GIVEN** a sweep group already stored with a static IPv6 prefix wider than /65
- **WHEN** core evaluates that group
- **THEN** the group is reported as not runnable
- **AND** it emits neither legacy status nor edge records

#### Scenario: A dropped mode does not refuse the group
- **WHEN** a sweep group's modes include arp and icmp
- **THEN** arp is dropped
- **AND** the icmp targets are still signed into the sweep plan

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
whose modes include mtr SHALL move as `MtrTraceBatchV1` under MTR check leases
when MTR checks move, with no dependency on that group's sweep lease.
Per-family parity soaks SHALL finish before cutover. The next release SHALL remove legacy agent
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
