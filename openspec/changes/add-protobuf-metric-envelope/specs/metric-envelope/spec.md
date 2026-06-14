## ADDED Requirements

### Requirement: Canonical Protobuf Metric Envelope
The platform SHALL define a single source-neutral protobuf message (`proto/metric/v1/metric.proto`,
schema `serviceradar.metric.v1`) that encodes the canonical metric field contract and SHALL generate
codecs for Go, Rust, and Elixir from it.

#### Scenario: Envelope preserves the canonical field set
- **WHEN** a metric is encoded into the canonical envelope
- **THEN** it SHALL carry, as typed fields, the metric `kind`, `temporality`, `is_monotonic`, `unit`, both `raw_value` and normalized `value`, the observed timestamp, the source/resource identity, point attributes, and `schema_version`
- **AND** the field set SHALL match `update-anomaly-evaluation-cadence` Decision 0 with no field dropped

#### Scenario: Codecs generated for all runtimes
- **WHEN** the proto is compiled
- **THEN** Go, Rust (prost), and Elixir (typed structs) codecs SHALL be generated from the one definition
- **AND** the build (including bazel/codegen) SHALL pass

### Requirement: Single Source-Neutral Wire Format
All non-OTLP native metric sources SHALL publish the canonical protobuf envelope on the existing
JetStream `metrics.*` subjects, with no per-source JSON metric envelope. Raw OTLP SHALL remain on the
OTLP protobuf path and SHALL NOT be rewrapped into this envelope.

#### Scenario: Every source uses one envelope
- **WHEN** sysmon, SNMP, ICMP checks, MTR scalar summaries, sweep scalar summaries and scanner stats, rperf summaries, native add-ons, or wasm plugins publish a scalar metric
- **THEN** the on-wire body SHALL be the canonical protobuf envelope on the existing `metrics.*` subjects
- **AND** producers SHALL NOT emit a per-family or per-metric JSON envelope

#### Scenario: OTLP remains OTLP
- **WHEN** raw OTLP metrics are published
- **THEN** they SHALL remain on the OTLP protobuf path
- **AND** producers SHALL NOT translate raw OTLP into the ServiceRadar metric envelope just to satisfy this change

#### Scenario: OTLP span-derived metrics use the ServiceRadar envelope
- **WHEN** the OTLP collector emits span-derived RED or performance samples on `otel.metrics.derived`
- **THEN** the on-wire body SHALL be the canonical protobuf envelope
- **AND** EventWriter SHALL decode that envelope into the existing `otel_metrics` persistence row shape
- **AND** JSON `PerformanceMetric` arrays SHALL NOT be accepted as a derived-metric compatibility path

#### Scenario: Producers encode directly without gateway re-encode
- **WHEN** a Go agent or an SDK collector emits a metric
- **THEN** it SHALL encode the protobuf envelope directly
- **AND** the agent-gateway SHALL NOT JSON-decode a status blob and re-encode it per family/metric

#### Scenario: Status JSON cannot duplicate native metric samples
- **WHEN** sysmon, SNMP, or sweep emits regular service status for health/read-model display
- **THEN** that status payload SHALL contain only bounded health/summary fields
- **AND** it SHALL NOT include full sysmon samples, SNMP OID values, sweep aggregate counts, scanner/banner counters, counter values, or other time-series metric values
- **AND** those metric values SHALL be emitted only through the canonical protobuf envelope on `metrics.*`

#### Scenario: Native add-on SDKs emit metric batches
- **WHEN** a native add-on using `go/pkg/addon/sdk` or `rust/addon-sdk` emits scalar metrics through `AddonService.StreamTelemetry`
- **THEN** the telemetry record payload SHALL be exactly one encoded `serviceradar.metric.v1.MetricBatch`
- **AND** the telemetry record SHALL use a ServiceRadar metric payload kind, not an OCSF, OTLP, derived-OTLP, or JSON plugin-result payload kind
- **AND** the agent-gateway SHALL publish it to the appropriate `metrics.*` subject with the metric data preserved and envelope-level resource, ingress, and ingest identity fields gateway-attested

#### Scenario: Wasm plugin SDKs carry binary metric batches through the host ABI
- **WHEN** a wasm plugin emits scalar metrics through `env.emit_telemetry`
- **THEN** the telemetry record payload SHALL represent exactly one encoded `serviceradar.metric.v1.MetricBatch`
- **AND** the telemetry record SHALL use the ServiceRadar metric payload kind
- **AND** any JSON host wrapper SHALL carry only an encoded binary payload, not JSON metric objects or arrays
- **AND** Go and Rust wasm SDKs SHALL provide dependency-free scalar `MetricBatch` encoders for common gauge and counter payloads
- **AND** the agent SHALL decode the wrapper back to raw protobuf bytes before forwarding telemetry toward the gateway

#### Scenario: Plugin result payloads cannot carry metrics
- **WHEN** a scheduled plugin or add-on returns a `serviceradar.plugin_result.v1` result payload
- **THEN** any `metrics` JSON key SHALL be rejected at the agent normalization boundary or by core before domain-result ingestion
- **AND** the payload SHALL NOT be treated as metric input by EventWriter, anomaly detection, or any direct-to-CNPG metric path
- **AND** plugin/add-on metric authors SHALL use the ServiceRadar metric telemetry payload kind instead

### Requirement: Typed Consumer Decoding
Metric consumers SHALL decode the protobuf envelope into typed fields exactly once, and SHALL NOT walk
string-keyed JSON maps or probe snake/camel field aliases.

#### Scenario: Single typed decode replaces JSON map-walking
- **WHEN** EventWriter or the anomaly `SampleExtractor` processes a metric
- **THEN** it SHALL read typed envelope fields from a single protobuf decode
- **AND** it SHALL NOT `Jason.decode` the metric body nor rebuild series identity by string concatenation

#### Scenario: No anomaly-engine internals in the producer wire format
- **WHEN** the envelope is defined and produced
- **THEN** it SHALL NOT expose anomaly-engine-internal representations such as shards, Welford accumulator state, or packed NIF records

### Requirement: Gateway-Attested Routing Fields
Envelope fields that route metrics versus derived records (`payload_kind`, `source`, `ingest_identity`) SHALL be
set or attested at the authenticated agent-gateway edge and SHALL NOT be trusted from an unauthenticated producer.
Metric semantic `kind` (gauge, sum, histogram) SHALL remain a typed metric field and SHALL NOT be used as the routing trust boundary.

#### Scenario: Untrusted routing class is overridden
- **WHEN** a relayed record carries a producer-supplied routing class that contradicts the gateway attestation
- **THEN** the consumer SHALL use the gateway-attested `payload_kind`/`source`/`ingest_identity`
- **AND** SHALL NOT route the record on the untrusted producer-supplied class

### Requirement: JetStream-First Ingestion Preserved
The canonical envelope SHALL preserve JetStream-first ingestion, message idempotency, and the existing
operational datastore.

#### Scenario: Transport and store are unchanged
- **WHEN** a metric envelope is published
- **THEN** it SHALL flow through JetStream first with `Nats-Msg-Id` idempotency on the `metrics` stream
- **AND** persistence SHALL remain CNPG/Timescale with no columnar datastore introduced

#### Scenario: Gateway owns metric status ingress
- **WHEN** an agent sends a metric status carrying a canonical protobuf envelope
- **THEN** agent-gateway SHALL publish the metric payload to JetStream before any core forwarding attempt
- **AND** metric-only status sources SHALL NOT be forwarded to core as result payloads
- **AND** core SHALL reject stale direct `*-metrics` status routing rather than treating it as a metric compatibility path

#### Scenario: Metric publish failures are not acknowledged
- **WHEN** agent-gateway cannot publish a canonical metric envelope to JetStream
- **THEN** it SHALL return an error to the caller
- **AND** it SHALL NOT acknowledge the metric status as successfully handled
- **AND** it SHALL NOT fall back to core result forwarding or direct database persistence
- **AND** a disabled metric publisher for a metric-only source SHALL be treated as an error, not as successful handling

### Requirement: Hard Cutover Without Dual-Accept
The migration SHALL be a single hard cutover with no long-lived dual-accept path, gated by a one-time
shadow/parity check.

#### Scenario: Producers and consumers switch together
- **WHEN** the cutover lands
- **THEN** all producers and all consumers SHALL use the protobuf envelope
- **AND** the JSON metric publishers and the JSON-first decode branch SHALL be removed, not retained as a fallback
- **AND** legacy `plugin_result.metrics[]` arrays SHALL NOT be accepted as a metric compatibility path
- **AND** the `update-anomaly-evaluation-cadence` "version-1 flat JSON gauge remains valid" clause SHALL be superseded

#### Scenario: Shadow/parity gate precedes the flip
- **WHEN** the cutover is validated before landing
- **THEN** an offline test SHALL encode synthetic batches as both JSON and protobuf, decode each, and assert field-level equality on kind/temporality/monotonicity/raw_value/value/observed_at/source-identity/attributes/schema_version
- **AND** SHALL assert equal CNPG rows and equal anomaly sample-extraction counts

### Requirement: Encoding Benchmark Gate
The change SHALL include a benchmark that compares the protobuf envelope against the current JSON path on
the standard synthetic workload.

#### Scenario: Benchmark reports the encoding cost axes
- **WHEN** the encoding benchmark runs
- **THEN** it SHALL report payload bytes, decode microseconds, allocation/memory delta, JetStream consumer msg/s, EventWriter persistence msg/s, and anomaly sample-extraction msg/s
- **AND** it SHALL capture the current JSON path as the baseline
- **AND** it SHALL demonstrate improvement in payload bytes and at least one measured decode, row-build, or sample-extraction stage-work axis
- **AND** any wall-clock, memory, JetStream, or persistence axis that does not improve SHALL be reported with a bottleneck note before cutover is accepted

### Requirement: Decode Observability
The change SHALL add telemetry for the metric decode boundary, registered so it reaches Prometheus and the
live dashboard.

#### Scenario: Decode failures and schema versions are observable
- **WHEN** envelope decoding runs in production
- **THEN** a decode-failure counter tagged by `reason` and a `schema_version` distribution signal SHALL be emitted
- **AND** envelope batch throughput, drops, and a decode/extract latency distribution SHALL be emitted
- **AND** all new metrics SHALL be registered in a `*_metrics/0` list reached by `Telemetry.metrics/0`
