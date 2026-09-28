# wasm-plugin-system Delta

## MODIFIED Requirements

### Requirement: Standardized Plugin Results
Plugins MUST use `serviceradar.plugin_result.v1` only for bounded health,
checker status, and summary output mapped to `GatewayServiceStatus`. Persistent
inventory, observations, telemetry, metrics, events, findings, traces,
enrichment, descriptors, and bulk results MUST use an assignment-approved binary
output contract through the agent-owned durable producer sink. Plugin results
MUST NOT carry durable dataset pages, artifact bytes, or continuous live media.

#### Scenario: Camera discovery plugin publishes descriptors
- **GIVEN** a camera discovery plugin has bounded status plus persistent source
  and stream descriptors
- **WHEN** the plugin publishes its outputs
- **THEN** service status ingestion SHALL preserve the bounded plugin status
  through `serviceradar.plugin_result.v1`
- **AND** the descriptors SHALL use the approved durable inventory contract and
  producer sink
- **AND** no live media bytes SHALL be expected in either record payload

#### Scenario: Plugin result without camera descriptors
- **GIVEN** a standard plugin result payload containing only bounded status and
  summary
- **WHEN** the payload is ingested
- **THEN** bounded checker/status ingestion SHALL behave exactly as before
- **AND** it SHALL NOT be used to introduce a new persistent dataset contract

### Requirement: Plugin Result Ingestion Compatibility
The gateway/core ingestion pipeline MUST retain compatibility for bounded
`serviceradar.plugin_result.v1` health/checker output during migration without
breaking existing checker ingestion. New persistent plugin outputs MUST NOT be
introduced through `plugin_result`; structured persistent perfdata, metrics, and
other durable records SHALL use assignment-approved binary contracts through the
durable producer sink and JetStream/EventWriter path.

#### Scenario: Dedicated result processor
- **GIVEN** a bounded plugin health/checker result in
  `serviceradar.plugin_result.v1`
- **WHEN** the gateway forwards the payload to core
- **THEN** core SHALL preserve compatible bounded status/summary behavior
- **AND** persistent structured output SHALL use its approved durable contract
  rather than being hidden in the status payload

#### Scenario: Bounded checker status remains a status path
- **GIVEN** bounded checker statuses arriving at the gateway
- **WHEN** durable plugin outputs are enabled
- **THEN** the checker status path MAY continue for coalescible health and
  bounded summaries
- **AND** it SHALL NOT become an alternate durable ingestion path for any
  persistent output contract

### Requirement: Runtime Telemetry Reporting
The agent MUST periodically report bounded Wasm runtime health and recent
execution status to the control plane. Coalescible runtime health MAY use the
normal `GatewayServiceStatus` pipeline. Persistent time-series resource samples,
execution events, findings, and other durable telemetry MUST use an approved
binary observability contract through the durable producer sink and SHALL become
subscribable in JetStream before CNPG persistence.

#### Scenario: Telemetry heartbeat
- **GIVEN** the agent has the Wasm runtime enabled
- **WHEN** the telemetry interval elapses
- **THEN** the agent MAY submit bounded coalescible engine health and recent
  execution status through `GatewayServiceStatus`
- **AND** persistent resource samples SHALL use the approved durable metric or
  observability contract rather than the status payload

#### Scenario: Runtime unhealthy
- **GIVEN** the Wasm runtime fails to initialize or repeatedly crashes
- **WHEN** the agent emits runtime telemetry
- **THEN** the bounded status SHALL indicate a degraded or unhealthy runtime
- **AND** the payload SHALL include a bounded, redacted failure reason
- **AND** any persistent incident/event record SHALL use its approved durable
  output contract

## ADDED Requirements

### Requirement: Wasm durable output uses a versioned binary host ABI
The agent SHALL expose a versioned Wasm host ABI and SDK for opening host-issued
runs, publishing bounded records, checkpointing, committing or
aborting, looking up uncertain receipts, and waiting for byte/frame credits.
The bounded contract-payload (submission) bytes SHALL cross guest memory through
one bounded copy and SHALL NOT be wrapped in base64 or JSON. The trusted sink --
never the guest -- constructs `EdgeRecordV1` from those submission bytes. The ABI
SHALL NOT expose
`EdgeRecordV1`, `EdgeDeliveryFrameV1`, spool coordinates, NATS subjects,
route/partition selection,
traffic class, trusted agent/network-scope provenance, projected database cost,
or database destinations to the guest.

#### Scenario: Guest publishes a metric batch
- **GIVEN** a plugin assignment grants the exact metric output contract
- **WHEN** the guest passes bounded contract-payload (submission) bytes and a
  stable producer key to the host ABI
- **THEN** the host SHALL validate the submission and the trusted sink SHALL
  construct and append the exact `EdgeRecordV1` through the common durable sink
- **AND** it SHALL NOT encode those submission bytes as protobuf-in-base64-in-JSON or let
  the guest construct transport routing

#### Scenario: Guest attempts to spoof routing
- **WHEN** a guest payload or metadata claims another agent, package, network
  scope, subject, traffic class, partition, or artificially low cost
- **THEN** the trusted sink SHALL ignore/replace non-authoritative claims or
  reject the submission before spool acceptance
- **AND** the effective assignment grant SHALL remain the sole authority

### Requirement: Plugin assignments carry approved output grants
Plugin assignments SHALL carry approved output grants. Import review MAY approve
a subset of the package's requested output contracts.
Compiled assignment grants SHALL bind exact contract bundle/version/digest,
registry epoch, package digest, host-issued producer assignment/run authority,
record/frame/run/rate/outstanding-spool/idempotency bounds, platform route
profile, immutable traffic class, cost model, and retirement/revocation state.
Output permission SHALL remain separate from HTTP, network, credential,
filesystem, and scanning host-function capabilities. Package output declarations
SHALL be requests only and SHALL NOT choose subjects, streams, traffic class,
partitions, database destinations, SQL/DDL, or executable Core processors.

#### Scenario: Admin narrows package outputs
- **GIVEN** a package requests inventory and findings outputs
- **WHEN** import review approves only bounded inventory output
- **THEN** compiled assignments SHALL omit the findings grant
- **AND** attempts to publish findings SHALL fail before durable acceptance

#### Scenario: Registry changes during a run
- **WHEN** a new registry epoch activates while an old run and spool backlog
  remain valid
- **THEN** that run/backlog SHALL remain pinned to its exact historical contract
  bundle according to retirement policy
- **AND** new runs SHALL use the newly compiled grant

#### Scenario: Package requests transport or storage authority
- **WHEN** a package output declaration includes a NATS subject, physical stream,
  traffic class, partition, database table, SQL/DDL, or executable processor
- **THEN** import/assignment validation SHALL reject that authority
- **AND** the platform-owned registry SHALL remain the sole route and projector
  authority

### Requirement: Plugin durable output is backpressured and idempotent
A guest SHALL supply bounded UNCOMPRESSED contract-payload (submission) bytes; the
sink SHALL compute `submission_sha256` over them and perform its retry lookup BEFORE
compression, then compress the payload once and construct the record. A
successful Wasm publish receipt SHALL mean the exact record bytes the sink emitted,
contract, producer key, and trusted provenance are fsynced in the common agent
spool. A retryable `WOULD_BLOCK` SHALL mean ownership did not transfer and SHALL
include bounded retry-after or credit notification. Permanent size, schema,
capability, revocation, and quota errors SHALL be distinct. The runtime SHALL
pause, fuel-limit, or terminate a guest that ignores pressure.

The sink SHALL atomically persist the stable producer-key binding with the spool
append, retain it for the supported retry horizon, and return the same durable
identity after a timeout or crash between fsync and reply. The same producer key
with a different `submission_sha256` SHALL be an integrity error.

#### Scenario: Host reply is lost after fsync
- **WHEN** a guest retries the same producer key after an uncertain host call
- **THEN** the sink SHALL return the original durable receipt and event identity
- **AND** it SHALL NOT create a second semantic record

#### Scenario: Plugin exhausts its output quota
- **WHEN** one plugin reaches its granted outstanding-spool or rate limit
- **THEN** it SHALL receive bounded backpressure or a permanent quota result as
  defined by the grant
- **AND** recovery and other producer assignments SHALL continue within their
  reserved capacity
