# Change: Canonical protobuf metric envelope over JetStream

## Why
Every metric source except OTLP is JSON/map-heavy on the wire, and the same scalar is
decoded and reshaped 3–4 times before it is evaluated. A Go agent `json.Marshal`s a status
payload into a generic protobuf `bytes` field (`StatusResponse.message` / `GatewayServiceStatus.message`);
the agent-gateway `Jason.decode`s that blob and fans it out into a brand-new per-family/per-metric
JSON envelope which it `Jason.encode`s back to NATS; EventWriter `Jason.decode`s it again to persist;
and the anomaly `SampleExtractor` `Jason.decode`s it a third time (plus a duplicate decode just for
ingress metadata), then walks string-keyed maps with multi-key snake/camel alias lookups and rebuilds
series identity by string concatenation. Only `otel.metrics.raw` and the native add-on relay are
already protobuf — and the relay (verbatim pass-through) is the cheapest source we have.

The canonical metric *field contract* is already designed (`update-anomaly-evaluation-cadence`
Decision 0 fixes `serviceradar.metric.v1` with `schema_version`, `resource`, `name`, `kind`,
`temporality`, `is_monotonic`, `unit`, `points[]`, `thresholds`, `ingress_id`,
`ingress_timestamp_unix_nano`, gateway-attested `ingest_identity`). What does not exist is a binary
**wire format** for it — it is encoded as JSON today. Both anomaly changes explicitly defer this to a
separate proposal (`optimize-anomaly-production-path-2m` task 3.6, migration step 7) and pre-wrote its
guardrail ("stream payload encoding remains source-neutral", anomaly-detection spec.md:62-65). This
change fills that gap: give the existing field contract a single source-neutral protobuf wire format so
non-OTLP native metric sources publish one typed envelope and consumers read typed fields instead of
decode-and-remap. Raw OTLP remains on the OTLP protobuf path.

## What Changes
- Define `proto/metric/v1/metric.proto` encoding the **exact** `serviceradar.metric.v1` field set from
  `update-anomaly-evaluation-cadence` Decision 0 (reuse, do not redefine). A source-neutral generalization
  of the OTLP NumberDataPoint/Sum/Gauge shape the Elixir side already decodes.
- Normalize non-OTLP native metric sources — sysmon, SNMP, ICMP check metrics, MTR scalar summaries,
  sweep scalar summaries and scanner stats, rperf summaries,
  native add-ons (`go/pkg/addon/sdk`, `rust/addon-sdk`), wasm plugins, and future custom collectors —
  onto this ONE envelope, published on the existing `metrics.*` subjects. Raw OTLP stays OTLP.
- Normalize OTLP span-derived RED/performance samples on `otel.metrics.derived` onto the same
  envelope while preserving the existing `otel_metrics` persistence schema. Raw OTLP metrics remain
  on `otel.metrics.raw` and are not rewrapped.
- Go agents, in-repo add-on SDKs, and standalone Go/Rust plugin SDKs
  (`/Users/mfreeman/src/serviceradar-sdk-go`, `/Users/mfreeman/src/serviceradar-sdk-rust`) emit the
  protobuf envelope **directly**, eliminating the gateway JSON decode-then-per-family/per-metric
  re-encode entirely. Sysmon, SNMP, and sweep regular status messages retain only lightweight health summaries;
  sampled metric values are not duplicated in JSON status payloads. Native add-ons that use
  `AddonService.StreamTelemetry` SHALL carry an encoded `serviceradar.metric.v1.MetricBatch` in the
  telemetry record payload, identified by a ServiceRadar metric payload kind, rather than a JSON metrics
  array.
- Replace the JSON `Jason.encode`/`Jason.decode` paths in the gateway publishers and in the EventWriter
  `Metrics` processor and the anomaly `SampleExtractor` with one protobuf decode that reads typed fields
  and stamps/reads `schema_version`. Do not rewrap `otel.metrics.raw`.
- **BREAKING — HARD CUTOVER:** there are no production users, so producers and both consumers (Elixir
  EventWriter/anomaly, Rust causal-engine) switch together behind one commit/tag. Delete the JSON
  publishers and the JSON-first decode branch; **supersede** `update-anomaly-evaluation-cadence`'s
  "legacy version-1 flat JSON gauge remains valid" dual-accept clause. No long-lived dual-accept path;
  the only safety net is a one-time offline shadow/parity check, and rollback is reverting the commit.
- Keep metrics **JetStream-first** with `Nats-Msg-Id` idempotency on the `metrics` stream; **CNPG/Timescale
  remains** the hot/warm store (no columnar datastore). Do **not** expose any anomaly-engine-internal shape
  (shards, Welford state, packed NIF records) in this producer wire format.
- Gateway-attest the envelope's `kind`/`source` fields: today `payload_kind`/`source` on relayed records is
  untrusted yet routes metrics-vs-derived (`OtlpRelayPublisher.route/2`).
- Add a benchmark gate (payload bytes, decode µs, allocations, JetStream consumer msg/s, EventWriter
  persistence msg/s, anomaly extraction throughput, against the current JSON path as baseline) and decode
  observability (decode-failure-by-reason, schema_version distribution, throughput/drops/latency).

## Impact
- Affected specs: `metric-envelope` (new), `native-addon-sdk` (new). Coordinates with `update-anomaly-evaluation-cadence`
  (`ingestion-routing` field contract + its legacy-gauge migration clause this change supersedes) and
  `optimize-anomaly-production-path-2m` (inherits the source-neutral-encoding requirement).
- Affected code: `proto/`, native add-on telemetry contract (`proto/agent/addon/v1/addon.proto`,
  `go/pkg/addon/sdk`, `rust/addon-sdk`, `go/pkg/agent/addon_telemetry.go`), agent-gateway publishers (`sysmon_metrics_publisher.ex`,
  `snmp_metrics_publisher.ex`, `icmp_metrics_publisher.ex`, `mtr_metrics_publisher.ex`,
  `rperf_metrics_publisher.ex`, `sweep_metrics_publisher.ex`, `plugin_metrics_publisher.ex`), Go agent emit paths, EventWriter
  `processors/metrics.ex`, EventWriter `processors/otel_metrics.ex`, `rust/otel`, anomaly `sample_extractor.ex`, Go/Rust/wasm
  metric-emit SDKs (`rust/addon-sdk`, plugin SDKs), `causal-engine` consumer, telemetry modules, and
  `bench/anomaly_detection_scale.exs`.
- Dependencies/coordination: `add-monotonic-counter-metric-semantics` (counter raw_value + reset anchors
  must be in the proto), `add-cgroup-v2-tenant-metrics`. `add-otel-messaging-sdk` is unrelated (trace
  propagation, not a metric envelope).
- Runtime impact: collapses 3–4 JSON decodes + per-family/per-metric re-encode to a single typed protobuf
  decode; removes snake/camel alias probing and string-concat series identity; smaller payloads; typed
  consumers in Elixir and Rust.
