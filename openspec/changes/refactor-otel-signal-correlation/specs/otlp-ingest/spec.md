## ADDED Requirements

### Requirement: OTLP/HTTP ingestion endpoint

The collector SHALL serve OTLP/HTTP on a dedicated port (default 4318) with
`POST /v1/traces`, `/v1/logs`, and `/v1/metrics` accepting
`application/x-protobuf` request bodies (with `Content-Encoding: gzip`
supported) and returning spec-compliant OTLP/HTTP responses including
`partial_success`. CORS SHALL be configurable (permissive by default) so
browser-based SDKs can export. OTLP/JSON SHOULD be accepted; if not yet
supported the server SHALL return 415 with an actionable message.

#### Scenario: http/protobuf default producer exports successfully

- **GIVEN** a stock SDK configured only with
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://<host>:4318` (http/protobuf default)
- **WHEN** it exports traces, logs, and metrics
- **THEN** all three POSTs SHALL return success and the data SHALL reach
  storage

#### Scenario: Browser SDK preflight

- **WHEN** a browser SDK issues a CORS preflight for `/v1/traces`
- **THEN** the configured CORS policy SHALL permit the request by default

### Requirement: OTLP/gRPC compression and message limits

The collector's gRPC services SHALL accept gzip-compressed requests (zstd
SHOULD be accepted) and SHALL enforce a configurable maximum decoded message
size (default ≥ 16 MiB) so stock OTel Collector exporters (gzip default,
large batches) ingest without configuration surgery.

#### Scenario: Stock OTel Collector exporter with gzip

- **GIVEN** an upstream OTel Collector `otlp` gRPC exporter with default
  `compression: gzip`
- **WHEN** it exports a batch
- **THEN** the request SHALL be accepted (no UNIMPLEMENTED)

#### Scenario: Large batch within limit

- **WHEN** an 8 MiB compressed batch arrives
- **THEN** it SHALL be decoded and processed rather than rejected at 4 MiB

### Requirement: External ingest transport posture

The OTLP ingest listener SHALL be deployable in a posture stock SDKs can
reach: client-certificate authentication SHALL be configurable as
required/optional/none on the OTLP listener independently of the platform's
internal mTLS, the Helm chart SHALL provide a first-class external exposure
option (LoadBalancer and/or Gateway route) for the OTLP ports, and the
shipped defaults SHALL document exactly which TLS material an external
sender needs (if any).

#### Scenario: External sender reaches the collector

- **GIVEN** a Helm install with the OTLP external service enabled
- **WHEN** an application outside the cluster sends OTLP to the published
  endpoint per the onboarding docs
- **THEN** the export SHALL succeed without a ServiceRadar-issued client
  certificate

#### Scenario: Internal mTLS unaffected

- **WHEN** the OTLP listener runs with `client_auth = none`
- **THEN** internal platform hops (NATS, intra-service gRPC) SHALL continue
  to require their existing mTLS

### Requirement: Per-record rejection semantics

The collector SHALL NOT convert a single unprocessable record into a failed
or infinitely-retried batch: oversized or malformed individual records SHALL
be dropped and counted, reported via `partial_success`
(`rejected_<signal>` + `error_message`) with an OK response, while
batch-level transport failures (message bus unavailable) SHALL remain
retryable errors. `partial_success` SHALL be unset on fully successful
exports for all three signals.

#### Scenario: One oversized log record

- **GIVEN** an export containing one 2 MiB log record among 100 normal ones
- **WHEN** the collector processes it
- **THEN** 99 records SHALL be ingested, the response SHALL be OK with
  `rejected_log_records: 1`, and the rejection SHALL be counted in metrics

#### Scenario: Clean export leaves partial_success unset

- **WHEN** an export is fully accepted
- **THEN** the response `partial_success` SHALL be unset for traces, logs,
  and metrics alike

### Requirement: Ingestion authentication for external senders

When the OTLP listener is exposed beyond the cluster, the system SHALL
support token-based ingestion authentication (header/metadata key) so
exposure does not mean anonymous write access, and the authenticated
identity SHALL be attached to the ingested data's envelope for downstream
attribution. Token enforcement SHALL be configurable (off for trusted
networks).

#### Scenario: Invalid token rejected

- **GIVEN** the ingest listener with token auth enabled
- **WHEN** an export arrives without a valid ingestion token
- **THEN** it SHALL be rejected with an authentication error

#### Scenario: Token identity attached

- **WHEN** an authenticated export is published to the message bus
- **THEN** the message envelope SHALL carry the authenticated sender
  identity

### Requirement: Stock-SDK conformance acceptance

The ingest surface SHALL be validated against two acceptance setups,
documented and repeatable: (1) an upstream OTel Collector `otlp` exporter
configured with only endpoint (+CA if TLS), all other settings default;
(2) a language agent/SDK configured with only `OTEL_EXPORTER_OTLP_ENDPOINT`.
Both SHALL successfully deliver traces, logs, and metrics end-to-end to
storage and the UI.

#### Scenario: telemetrygen end-to-end

- **WHEN** `telemetrygen` sends traces, logs, and metrics at the published
  endpoint with default settings (plus documented TLS material if required)
- **THEN** the traces appear in the trace list with correct span counts and
  status, the logs in the logs pane with correct severity, and the metrics
  as queryable metric points with correct name, type, unit, and value

### Requirement: Edge OTLP ingestion via agent-coupled collector add-on

The OTel collector SHALL be packaged as a native add-on deployable alongside
serviceradar-agent through the existing native add-on framework (delivery
models, signing, edge-ops lifecycle, streamed agent configuration), providing
local OTLP ingestion (gRPC, and HTTP once available centrally) at edge sites.
Telemetry accepted at the edge SHALL be forwarded into the platform over the
EXISTING agent→agent-gateway channel — requiring no new inbound ports at the
edge site and no egress beyond the agent's established connection — and SHALL
terminate in the same ingestion pipeline (same NATS subjects/tables) as
centrally-ingested OTLP.

#### Scenario: Edge app exports without new network surface

- **GIVEN** an edge site whose only allowed connection is the agent's
  existing gateway link
- **WHEN** an application at that site exports OTLP to the local collector
  add-on
- **THEN** its traces, logs, and metrics SHALL arrive in platform storage
- **AND** no additional firewall rules or inbound listeners SHALL be required
  beyond the local-network OTLP listener itself

#### Scenario: Add-on lifecycle follows the framework

- **WHEN** an operator assigns the collector add-on to an agent
- **THEN** delivery, verification (signing), upgrade, and removal SHALL work
  through the same mechanisms as other native add-ons, with configuration
  delivered via streamed agent config

### Requirement: Edge collector transport selection

The edge collector add-on SHALL support two selectable forwarding
transports: (a) agent-channel — encoded OTLP batches relayed through the
local serviceradar-agent's existing gateway connection (default for sites
whose only allowed path is the gateway link), and (b) direct NATS
JetStream — publishing to a site-local NATS leaf server when one is
deployed, in which case durable store-and-forward across cloud
disconnects is provided by the leaf's JetStream rather than the add-on's
own buffer. Downstream consumers SHALL receive identical data regardless
of transport. Leaf-mode stream provisioning SHALL be leaf-safe: the
collector SHALL NOT force-reconcile hub/shared stream configuration when
publishing to a leaf domain.

#### Scenario: Leaf transport survives cloud disconnect

- **GIVEN** an edge site running a NATS leaf server and the collector
  add-on configured with the JetStream transport against the local leaf
- **WHEN** the edge↔cloud link drops for an extended period while
  applications keep exporting OTLP locally
- **THEN** telemetry SHALL accumulate durably in the leaf's local stream
- **AND** SHALL reach platform storage after the link is restored, within
  the leaf stream's configured retention bounds

#### Scenario: Transport choice is configuration, not code

- **WHEN** an operator switches an edge collector between agent-channel
  and leaf JetStream transports via add-on configuration
- **THEN** no application-facing change SHALL be required and downstream
  data SHALL remain identical

### Requirement: Edge-ingested telemetry parity and attribution

Telemetry ingested at the edge SHALL be indistinguishable downstream from
centrally-ingested OTLP — same canonical ID encoding, fidelity, correlation,
and UI behavior — and SHALL carry site/agent attribution derived from the
agent's authenticated identity (agent id, partition/site) stamped during
forwarding, without requiring edge applications to configure ingestion
tokens.

#### Scenario: Edge trace correlates like a central trace

- **WHEN** a multi-span trace is ingested via an edge collector add-on
- **THEN** its spans, summary, correlated logs, and stat-card contributions
  SHALL behave identically to the same trace ingested centrally

#### Scenario: Attribution from agent identity

- **WHEN** edge-ingested telemetry is stored
- **THEN** it SHALL be queryable by the originating agent/site identity
- **AND** that identity SHALL come from the agent's mTLS identity, not
  sender-supplied attributes

### Requirement: Intermittent-link buffering for edge telemetry

The edge collector add-on SHALL buffer telemetry locally (bounded, with
oldest-first eviction and drop accounting) when the agent→gateway link is
unavailable, and SHALL drain the buffer on reconnect, consistent with the
platform's store-and-forward edge architecture.

#### Scenario: Link outage does not lose recent telemetry

- **GIVEN** an edge site whose gateway link drops for 10 minutes
- **WHEN** applications continue exporting OTLP locally during the outage
- **THEN** buffered telemetry within the configured bound SHALL be delivered
  after reconnect
- **AND** anything evicted SHALL be counted in delivery accounting

### Requirement: Platform self-telemetry through the edge collector

ServiceRadar's own edge components SHALL be able to export their telemetry
(traces, logs, metrics) to the local collector add-on when present — the
agent, its plugins, and other native add-ons alike — so fleet observability
covers the edge runtime itself without separate telemetry plumbing per
component.

#### Scenario: Agent runtime telemetry reaches the platform

- **GIVEN** an agent with the collector add-on deployed and self-telemetry
  enabled
- **WHEN** the agent or one of its add-ons emits OTLP telemetry locally
- **THEN** it SHALL appear in the platform's observability UI attributed to
  that agent/site

### Requirement: Edge spool retention is operator-managed and observable

The edge collector add-on's spool retention SHALL be operator-configurable
through the add-on settings UI via the add-on configuration schema (maximum
size, maximum age, and free-disk floor), with bounded defaults (no
multi-gigabyte allocation required); shrinking the configured bound SHALL
take effect immediately by evicting oldest segments down to the new bound;
and when the host volume's free space falls below the configured floor the
spool SHALL behave as bound-reached (evict-oldest, counted rejection on
persistent failure) rather than filling the disk or crashing.

#### Scenario: Retention configured from the settings UI

- **WHEN** an operator changes the spool's maximum size in the add-on
  settings
- **THEN** the running add-on SHALL apply the new bound without restart
- **AND** if the new bound is smaller than current usage, oldest segments
  SHALL be evicted immediately with evictions counted

#### Scenario: Host disk pressure does not fill the volume

- **GIVEN** the volume's free space drops below the configured floor while
  the spool is under its own bound
- **WHEN** new telemetry arrives during a link outage
- **THEN** the spool SHALL evict oldest data to make room rather than
  growing, and persistent write failure SHALL reject with accounting, never
  crash

### Requirement: Spool usage reported as OCSF events

The edge collector add-on SHALL report spool usage through the platform's
event pipeline: OCSF events emitted via the add-on SDK's telemetry stream on
utilization threshold transitions (rising and clearing) and while eviction
is active, carrying spool bytes used, configured bound, utilization
percentage, free disk space, and per-signal evicted-record counts — so
operators can alert on edge buffering pressure with the existing
event-to-alert rules.

#### Scenario: Threshold crossing emits an event

- **WHEN** spool utilization rises past a reporting threshold (e.g. 80%)
- **THEN** an OCSF event SHALL be emitted via the SDK telemetry stream with
  the usage attributes
- **AND** a clearing event SHALL be emitted when utilization falls back
  below the threshold

#### Scenario: Eviction pressure is alertable

- **GIVEN** a stateful alert rule matching spool-pressure events
- **WHEN** an edge site evicts telemetry during an extended outage
- **THEN** the emitted events SHALL be sufficient to trigger and resolve the
  alert through the existing event-to-alert pipeline
