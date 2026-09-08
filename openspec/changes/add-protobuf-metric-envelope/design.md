## Context
The canonical metric *field contract* is already owned and fixed by `update-anomaly-evaluation-cadence`
Decision 0 (`serviceradar.metric.v1`), but it is encoded as JSON. The only protobuf in the metric path
is a generic transport wrapper (`StatusResponse.message` / `GatewayServiceStatus.message`, both `bytes`)
carrying an opaque JSON body — there is no metric message in `proto/`. Sysmon, SNMP, and plugin/wasm
metrics each pay: agent JSON-marshal → gateway `Jason.decode` → per-family/per-metric JSON re-encode →
EventWriter `Jason.decode` → anomaly `SampleExtractor` `Jason.decode` (×2). OTLP (`otel.metrics.raw`)
and the native add-on relay are already protobuf and prove the typed decode-then-remap path is correct
and cheap on the Elixir side (`processors/otel_metrics.ex`). Span-derived OTLP RED samples on
`otel.metrics.derived` were the remaining metric-shaped JSON exception; this change converts them to the
same ServiceRadar `MetricBatch` envelope while preserving the existing `otel_metrics` storage table.

This change defines the binary wire format for the already-specified field contract. It is the separate
proposal that `optimize-anomaly-production-path-2m` (task 3.6, migration step 7) and the cadence change
deferred.

## Goals / Non-Goals
- Goals:
  - One source-neutral protobuf envelope for non-OTLP native metric sources: sysmon, SNMP, ICMP checks,
    MTR scalar summaries, sweep scalar summaries and scanner stats, rperf summaries, native add-ons,
    wasm plugins, OTLP span-derived RED samples on `otel.metrics.derived`, and future custom collectors.
    Raw OTLP remains on the OTLP protobuf path.
  - Preserve metric kind, temporality, monotonicity, raw_value+value, observed timestamp, source/resource
    identity, attributes, unit/scale, and schema_version as TYPED fields.
  - Collapse the JSON decode-reshape-reencode middle to a single protobuf decode in producers and consumers
    (Elixir EventWriter + anomaly; Rust causal-engine).
  - JetStream-first preserved; `Nats-Msg-Id` idempotency preserved; CNPG/Timescale unchanged.
  - A benchmark gate proving the win, and decode observability.
- Non-Goals:
  - Bypassing JetStream or writing metrics directly to CNPG.
  - Adding a columnar datastore (Arrow-as-wire is not a columnar store and is out of scope).
  - Exposing anomaly-engine internals (shards, Welford state, packed NIF records) in the producer wire format.
  - Re-designing the metric FIELD contract — reuse cadence Decision 0 verbatim.
  - Long-lived backward compatibility / dual-accept of the old JSON envelope (see Decision 4).
  - Changing evaluation cadence, counter normalization semantics, or anomaly output shape.

## Decisions

### Decision 1: Protobuf (proto3), generated for Go, Rust, and Elixir
Adopt protobuf as the single canonical `serviceradar.metric.v1` JetStream envelope, generated with the
repo's existing proto toolchain into Go (`.pb.go`), Rust (`prost`; add the envelope crate to the workspace
and `causal-engine`, and reuse it from `rust/addon-sdk` for native add-ons and Rust collectors), and Elixir
(`protobuf` 0.16 typed structs — the same generated-protobuf style `OtelMetrics` already uses for raw OTLP).

- Alternatives considered:
  - **FlatBuffers / Cap'n Proto (zero-copy):** rejected. Both consumers must fully materialize every field
    into Elixir term maps / CNPG row maps and Rust structs anyway, so the zero-copy advantage is erased —
    the identical decode-then-remap reality that already caused the **packed-binary NIF ABI to be rejected**.
    Elixir tooling is also immature.
  - **Arrow IPC:** rejected. Columnar advantage is irrelevant at tens-to-low-hundreds of scalar points per
    message and under the no-columnar-store + JetStream-first constraints; wrong tool despite being in-repo.
  - **JSON (status quo):** rejected. It is the cost being removed (double decode + triple map-walk + alias
    probing + per-metric re-encode).
- Why protobuf wins here specifically: it already works in all four runtimes; OTLP already proves typed
  decode is cheap on Elixir; varint-packed payloads are small (well under NATS' 1 MB); typed structs kill
  the snake/camel key probing and map churn; and it has the strongest schema-evolution story for a contract
  that is half-specified already.

### Decision 2: Model the message on the OTLP NumberDataPoint shape, source-neutral
The message generalizes OTLP Sum/Gauge/NumberDataPoint, carrying the cadence Decision 0 fields:
`schema_version`, `resource` (agent_id / gateway_id / partition_id / service identity), `name`, `kind`
(gauge|sum|histogram), `temporality` (delta|cumulative|unspecified), `is_monotonic`, `unit`, and a
repeated `points[]` where each point carries `value` (normalized) + `raw_value` (pre-normalization),
`observed_at_unix_nano`, `start_time_unix_nano` / reset anchor (for monotonic counters), point `attributes`,
and the derived `series_identity` / semantic keys so consumers stop string-concatenating them.
`thresholds`, `ingress_id`, `ingress_timestamp_unix_nano`, and gateway-attested `ingest_identity` are
envelope-level. Field numbers are reserved conservatively to allow additive evolution.

### Decision 2A: Native add-on telemetry carries encoded MetricBatch payloads
Native add-ons already have an in-repo SDK and telemetry stream:
`proto/agent/addon/v1/addon.proto`, `go/pkg/addon/sdk`, `rust/addon-sdk`, and the agent-side bridge in
`go/pkg/agent/addon_telemetry.go`. This change SHALL extend that telemetry contract with a ServiceRadar
metric payload kind whose `TelemetryRecord.payload` is exactly one encoded
`serviceradar.metric.v1.MetricBatch`. SDK helpers in both Go and Rust SHALL build that batch directly so
add-on authors do not hand-roll JSON metric arrays.

This keeps native add-ons on the same JetStream-first path as sysmon/SNMP/ICMP while preserving the
existing `StreamTelemetry` transport. The external plugin SDK repos
(`/Users/mfreeman/src/serviceradar-sdk-go` and `/Users/mfreeman/src/serviceradar-sdk-rust`) follow the
same rule: `plugin_result` remains status/domain output only, while time-series metrics use the
ServiceRadar metric telemetry payload kind carrying an encoded `MetricBatch`. Raw OTLP relay records
remain OTLP and are not rewrapped.

### Decision 2B: Wasm plugin metrics use a binary MetricBatch payload inside the host ABI
Wasm plugins already emit first-class telemetry through the `env.emit_telemetry` host import. That host ABI
is JSON because it carries mixed signal types, but metric telemetry SHALL NOT place JSON metric objects in
that wrapper. A wasm plugin metric record SHALL use the ServiceRadar metric payload kind and carry a
base64-encoded, already-marshaled `serviceradar.metric.v1.MetricBatch`; the agent host decodes that base64
field immediately back to raw protobuf bytes before spooling the add-on telemetry batch. JSON object/array
payloads for the ServiceRadar metric payload kind are invalid.

This keeps the wasm ABI stable while preventing the legacy `plugin_result.metrics[]` JSON shape from
becoming another metric ingestion path.

The standalone Go and Rust wasm SDKs SHALL provide dependency-free scalar `MetricBatch` builders/encoders
for plugins. Plugin authors should not need to import the full Go protobuf runtime in TinyGo or hand-roll
wire bytes just to emit a gauge/counter; the SDK-owned encoder is the only sanctioned escape hatch from the
JSON host ABI for metric payloads. Callers that already have encoded `MetricBatch` bytes may still wrap
those bytes directly.

The scheduled plugin-result contract remains for domain/status output only. If a `serviceradar.plugin_result.v1`
payload contains a `metrics` key after the cutover, the Go agent SHALL reject it at normalization time; the
core router SHALL reject stale/replayed payloads that still contain the key instead of sanitizing them into
domain results. Neither branch is a metric compatibility path.

First-party wasm plugins that previously populated `plugin_result.metrics[]` SHALL preserve those time-series
signals by emitting a ServiceRadar metric telemetry record instead. The initial migration covers AXIS camera
health metrics, UniFi Protect camera/stream/event counts, and Proxmox inventory/resource summary metrics.

### Decision 3: Gateway-attested payload/source identity (trust boundary)
`source`/`payload_kind` route metrics-vs-derived today (`OtlpRelayPublisher.route/2`) and are untrusted on
relayed records. The envelope's routing-affecting fields (`payload_kind`, `source`, `ingest_identity`) SHALL
be set/attested at the authenticated agent-gateway edge; consumers SHALL NOT trust a producer-supplied
routing class that contradicts the gateway attestation. Metric semantic `kind` (gauge/sum/histogram) remains
typed metric data, not the routing trust boundary.

The gateway may re-encode the envelope to stamp attested envelope-level identity and ingress fields. That is
not a return to JSON reshaping: metric names, points, values, attributes, and counter semantics remain typed
protobuf fields and are not converted through a per-family/per-metric JSON envelope.

### Decision 4: Hard cutover, no dual-accept
ServiceRadar has no production users, so this is a single-commit cutover: all producers and both consumers
switch to the envelope at once. Delete the JSON publishers and JSON metric-ingest branches
(sysmon/SNMP/ICMP/MTR/sweep/rperf/plugin-result, plus any add-on bridge that would translate metrics through JSON);
do not port a dual-accept path. The direct sysmon-to-CNPG `SysmonMetricsIngestor` module is removed rather
than left as dormant compatibility code; sysmon scalar persistence now enters through `metrics.sysmon.*` and
the EventWriter metrics consumer. This change
**supersedes** the cadence "version-1 flat JSON gauge remains valid" migration clause — that scenario is
removed, not honored. The only safety net is a one-time offline shadow/parity check (Decision 5); rollback
is reverting the commit/tag.

Regular sysmon, SNMP, and sweep service status JSON remains allowed only for health/read-model summaries. It
SHALL NOT duplicate full sysmon samples, SNMP OID values, sweep aggregate counts, scanner/banner counters,
counter values, or other time-series metric payloads; those values move exclusively through
`serviceradar.metric.v1.MetricBatch` on the `metrics.*` path. This prevents a "protobuf for persistence,
JSON for status" shadow metric channel from surviving the hard cutover.

### Decision 5: Shadow/parity gate before the flip
Before the cutover commit, a one-time offline test encodes synthetic metric batches both ways (old JSON and
new protobuf), decodes each, and asserts field-level equality on kind/temporality/monotonicity/raw_value/
value/observed_at/source-identity/attributes/schema_version, plus equal CNPG rows and equal anomaly
sample-extraction counts. This is a test, not a runtime dual path.

### Decision 6: Benchmark gate
Extend `bench/anomaly_detection_scale.exs` with a decode-stage mode reusing its dataset/memory/monotonic
scaffolding. Report, per source profile: payload bytes, decode microseconds, allocation/memory delta,
JetStream consumer msg/s, EventWriter persistence msg/s, and anomaly sample-extraction msg/s — with the
current JSON path captured as the baseline. The release gate is not "protobuf wins every wall-clock sample";
it is "protobuf cuts wire bytes, improves at least one timed decode/row-build/extract stage-work axis, and
any wall-clock, memory, JetStream, or persistence miss has an explicit bottleneck note." Short BEAM
wall-clock runs and post-GC memory deltas are useful smoke signals, but they are noisier than payload bytes
and summed stage timers.

Note on what protobuf wins: the measured benefit is a decode/extraction/payload win (decode ~-35%,
extract ~-19%, payload ~-57% on the fixtures below) — not a detector eval/s win. The anomaly evaluator's
eval/s is downstream of decode and is unchanged by the envelope format, so these numbers must not be read
as an eval/s improvement.

Current decode-stage implementation evidence:

- `ANOMALY_BENCH_SERIES=50_000 ANOMALY_BENCH_BASELINE=12 ANOMALY_BENCH_ANOMALY=3
  ANOMALY_BENCH_BATCH_SIZE=1000 ANOMALY_BENCH_CONCURRENCY=16` decoded and row-shaped 750,000 rows from
  750 messages on the local workstation. Both modes now build the production-shaped row fields, including
  `DateTime` timestamps and `created_at`:

  | mode | elapsed | rows/s | messages/s | summed decode+row ns/row | memory delta | payload bytes |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | `metric_envelope_decode` | 1.107s | 677,755 | 678 | 5,829 | 6.65 MB | 144,005,980 |
  | `metric_json_decode_baseline` | 1.208s | 620,738 | 621 | 7,133 | 3.87 MB | 329,759,480 |

  The protobuf envelope cuts bytes by ~56%, improves this fair decode+row-shape harness by ~9.2% wall-clock
  and ~18.3% summed decode+row time on the 2026-06-14 rerun. The instantaneous BEAM memory delta is noisier than allocation
  telemetry and was higher on this serial run, so the claim is deliberately based on payload bytes and timed
  decode/row-shape work rather than a single post-GC memory snapshot. The expected
  production win is still not "protobuf alone decodes orders of magnitude faster"; it is deleting the
  current multi-hop path:
  agent JSON marshal -> gateway JSON decode -> gateway per-family/per-metric JSON encode -> EventWriter
  JSON decode -> anomaly SampleExtractor JSON decode/string-key remap. The final benchmark gate must still
  measure that end-to-end removal, including persistence and sample extraction, before claiming a broader
  throughput or allocation improvement.

  A later local rerun with lower concurrency
  (`ANOMALY_BENCH_SERIES=50_000`, `ANOMALY_BENCH_BASELINE=10`, `ANOMALY_BENCH_ANOMALY=5`,
  `ANOMALY_BENCH_BATCH_SIZE=1000`, `ANOMALY_BENCH_CONCURRENCY=4`) showed why the gate is phrased this
  way: protobuf still cut payload bytes and summed decode work, but JSON was a few percent faster by elapsed
  wall time in that short run. The protobuf decode fixture processed 750,000 rows in 2.158s
  (347,512 rows/s), with 142,917,980 payload bytes and 5,084 ns/row summed decode work. The JSON fixture
  processed the same rows in 2.090s (358,805 rows/s), with 327,584,480 payload bytes and 6,119 ns/row
  summed decode work. That is a protobuf win on bytes (~56.4% smaller) and timed stage work (~16.9% fewer
  ns/row), but not on that wall-clock sample.

- `metric_envelope_extract` adds the production anomaly `SampleExtractor.extract/1` stage. The first
  protobuf extraction harness exposed that the anomaly path was still decoding through the EventWriter
  row mapper and then rebuilding samples from row maps. The current implementation decodes
  `serviceradar.metric.v1.MetricBatch` directly, writes typed semantic fields (`kind`, `temporality`,
  `raw_value`, counter width, ingress identity) into sample metadata, and avoids the JSON alias-lifting
  scan on the metric hot path. On the same 50k-series/750k-row workload, the protobuf extraction mode
  improved from 307,831 samples/s before the hash/identity cleanup, to 380,472 samples/s after that cleanup,
  to 524,678 samples/s after direct typed extraction, and to 569,544 samples/s after the typed ingress fast path:

  | mode | elapsed | samples/s | messages/s | extract ns/sample | memory delta | payload bytes |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | `metric_envelope_extract` before direct typed extraction | 1.971s | 380,472 | 380 | 24,728 | 6.78 MB | 144,017,230 |
  | `metric_envelope_extract` direct typed extraction, 2026-06-14 rerun before alias-scan cut | 1.429s | 524,678 | 525 | 7,674 | 4.66 MB | 144,005,980 |
  | `metric_envelope_extract` after typed ingress fast path | 1.317s | 569,544 | 570 | 6,741 | -17.04 MB | 144,005,980 |
  | `metric_envelope_extract` after metric-context hoist | 1.318s | 569,116 | 569 | 6,797 | 3.99 MB | 142,917,980 |
  | `metric_json_extract_baseline` benchmark fixture, same session | 1.360s | 551,411 | 551 | 8,934 | 10.81 MB | 327,584,480 |

  The legacy JSON extraction baseline is a benchmark-only compatibility fixture, not a runtime path. Its
  payload is still ~2.3x larger than the protobuf envelope. The protobuf `SampleExtractor.extract/1`
  stage is ahead on wall-clock fixture time, summed extraction time, and payload bytes after the typed
  ingress fast path. That hot-path cut avoids scanning the fully assembled sample metadata map for
  snake/camel event-id aliases when a protobuf batch already carries typed ingress identity. The
  instantaneous memory delta remains noisy, especially after prior runs in the same BEAM VM; use payload
  bytes and timed stage work as the reliable comparison.

  Earlier local verification after the metric-context hoist
  (`ANOMALY_BENCH_SERIES=50_000`, `ANOMALY_BENCH_BATCH_SIZE=1000`, source `generic`) kept the same
  direction. Protobuf decode processed 750,000 rows in 1.287s (582,826 rows/s), with 144,005,980 payload
  bytes and 7,151 ns/row summed decode work; the benchmark-only JSON fixture processed the same rows in
  1.320s (568,104 rows/s), with 329,759,480 payload bytes and 7,861 ns/row. Protobuf extraction processed
  750,000 samples in 1.318s (569,116 samples/s), with 6,797 ns/sample summed extract work; the JSON fixture
  processed the same samples in 1.360s (551,411 samples/s), with 8,934 ns/sample. Non-persistence benchmark
  modes should be run with the harness' documented `mix run --no-start` invocation so the application
  supervisor does not start the repo pool and inject unrelated localhost-CNPG retry noise into short timing
  samples.

  A smaller 10k-series rerun of the extraction pair reinforced the same caveat. Protobuf extracted 150,000
  samples in 0.399s (376,220 samples/s), with 28,182,780 payload bytes and 4,823 ns/sample summed extract
  work. The benchmark-only JSON fixture extracted the same samples in 0.348s (430,963 samples/s), with
  65,117,080 payload bytes and 5,610 ns/sample summed extract work. Again, protobuf won bytes (~56.7%
  smaller) and stage work (~14.0% fewer ns/sample), while elapsed wall time favored JSON in that short
  sample. The design therefore treats wall-clock fixture misses as bottlenecks to explain, not as evidence
  that a runtime JSON compatibility path should remain.

  A previous 5k-series smoke rerun after the hard-cutover cleanup kept the same direction on the
  default generic profile. Protobuf decode processed 75,000 rows in 0.123s (611,262 rows/s), with
  14,175,085 payload bytes and 5,917 ns/row summed decode work; the benchmark-only JSON fixture
  processed the same rows in 0.138s (545,403 rows/s), with 32,751,110 payload bytes and 8,342 ns/row.
  Protobuf extraction processed 75,000 samples in 0.142s (527,827 samples/s), with 7,087 ns/sample
  summed extract work; the JSON fixture processed the same samples in 0.144s (519,286 samples/s),
  with 9,750 ns/sample and a larger memory delta. EventWriter protobuf row-build processed the same
  75,000 rows in 0.124s (607,219 rows/s), with 5,803 ns/row summed row-build work. The native
  add-on-shaped profile in the same smoke rerun processed 75,000 protobuf rows at 318,883 rows/s for
  decode, 318,939 rows/s for EventWriter row-build, and 299,799 samples/s for anomaly extraction,
  with 31,477,014 payload bytes. That profile is deliberately richer than the generic shape because it
  models `AddonService.StreamTelemetry` payloads from `go/pkg/addon/sdk` and `rust/addon-sdk`.

- `ANOMALY_BENCH_METRIC_SOURCE` selects source-shaped payloads (`generic`, `sysmon`, `snmp`, `icmp`,
  `mtr`, `sweep`, `rperf`, `plugin`, `addon`, `otel_derived`) for
  the protobuf benchmark modes. `metric_envelope_eventwriter_rows` uses the real
  EventWriter decode + row-build path before CNPG insert. `otel_derived` routes through
  `ServiceRadar.EventWriter.Processors.OtelMetrics.parse_message/1` on subject `otel.metrics.derived`;
  the other sources route through `ServiceRadar.EventWriter.Processors.Metrics.parse_message/1`.
  On the same 50k-series/750k-row workload:

  | source | row-build rows/s | row-build messages/s | extraction samples/s | extraction messages/s | payload MB |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `generic` | 750,903 | 751 | 613,485 | 613 | 137.33 |
  | `sysmon` | 637,388 | 637 | 520,618 | 521 | 159.51 |
  | `snmp` | 450,747 | 451 | 375,256 | 375 | 200.83 |
  | `icmp` | 306,468 | 306 | 377,199 | 377 | 189.13 |
  | `mtr` | 239,981 | 240 | 218,481 | 218 | 292.54 |
  | `sweep` | 236,214 | 236 | 234,704 | 235 | 321.82 |
  | `rperf` | 336,213 | 336 | 256,127 | 256 | 255.56 |
  | `plugin` | 502,958 | 503 | 362,060 | 362 | 204.83 |
  | `addon` | 289,878 | 290 | 242,171 | 242 | 302.31 |
  | `otel_derived` | 106,477 | 106 | 109,013 | 109 | 407.50 |

  The SNMP, ICMP, MTR, sweep, rperf, wasm plugin, native add-on, and OTLP-derived shapes are slower because they carry richer
  source-specific tags and metadata (counter semantics, OID/interface identity, target identity,
  producer/status tags, hop/path identity, scanner identity, SDK/transport identity, trace/span
  identity, and RED/http/grpc attributes), but they still use the same canonical protobuf envelope.
  The `addon` profile is intentionally separate from `plugin`: it models native add-ons using
  `AddonService.StreamTelemetry` through `go/pkg/addon/sdk` and `rust/addon-sdk`, not wasm
  `plugin_result` metrics. The `otel_derived` profile is intentionally separate from raw OTLP metrics:
  raw OTLP remains on `otel.metrics.raw`, while span-derived RED/performance samples use
  `serviceradar.metric.v1.MetricBatch` on `otel.metrics.derived` and preserve the existing
  `otel_metrics` row shape. These are in-memory decode/row-build/extract figures, not a substitute for the
  environment-backed JetStream consumer and CNPG persistence gate. The benchmark harness includes
  `metric_envelope_eventwriter_persist` for the CNPG insert portion; run it with a unique
  `ANOMALY_BENCH_RUN_ID` so `ON CONFLICT` does not hide insert throughput on repeated runs.

  Runtime source routing is part of the cutover evidence: sysmon, SNMP, ICMP, MTR, sweep, and rperf attach
  `*-metrics` sources only to successfully marshaled `serviceradar.metric.v1.MetricBatch` payloads. RPerf
  keeps JSON health/status fallback payloads on `source=status` unless the bytes decode as a valid metric
  envelope. Gateway publishers then reject invalid protobuf for metric sources and never publish those
  fallback status payloads to `metrics.*`.

  A follow-up smoke run with `ANOMALY_BENCH_SERIES=1000`, `ANOMALY_BENCH_BASELINE=2`,
  `ANOMALY_BENCH_ANOMALY=1`, and `ANOMALY_BENCH_BATCH_SIZE=250` verified both
  `metric_envelope_eventwriter_rows` and `metric_envelope_extract` for all ten source profiles at
  3,000 rows/samples per source with zero failed series. That smoke matrix is intended to catch source
  selector regressions quickly; the 50k-series table above is the release-signoff profile for the in-memory
  decode/row-build/extract boundary.

- `metric_envelope_eventwriter_persist` measures the real EventWriter `Metrics.process_batch/1` path through
  protobuf decode, row construction, and `platform.timeseries_metrics` insertion on a migrated CNPG database.
  The 2026-06-14 fixture run used a scratch database in the `srql-fixtures` CNPG cluster reached through the
  `srql-fixture-rw-ext` NodePort (`sslmode=require`), with 5k series, 15 samples per series, 1k rows per NATS
  payload, and pool/concurrency 4. It persisted 75k rows per source shape with zero rejects:

  | source | persisted rows/s | messages/s | rows | payload bytes | persistence ns/row |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `generic` | 18,136 | 18 | 75,000 | 17,682,085 | 161,443 |
  | `sysmon` | 14,052 | 14 | 75,000 | 19,857,835 | 212,303 |
  | `snmp` | 14,991 | 15 | 75,000 | 23,767,710 | 188,033 |
  | `plugin` | 15,008 | 15 | 75,000 | 24,609,360 | 218,957 |

  This is intentionally a storage-path benchmark, not a protobuf decoder ceiling. It includes Timescale
  hypertable/index work and NodePort/database latency, so it is orders of magnitude below the in-memory
  decode/row-build stage and identifies CNPG persistence as the dominant remaining environment-backed cost.
  The JetStream/Broadway consumer delivery profile remains a separate gate because this direct processor run
  does not exercise broker pull, ack, or Broadway batching behavior.

- `metric_envelope_eventwriter_pipeline` measures a real JetStream-to-Broadway-to-CNPG path. The 2026-06-14
  run started a local single-node `nats-server -js`, let the EventWriter producer create/use the `metrics`
  JetStream stream and durable consumer, published 75 protobuf metric batches, and waited until the migrated
  CNPG scratch database (a NodePort-reached `srql-fixtures` scratch DB, not production CNPG) contained all
  75k expected rows for the run-id. The reported rate also folds in producer startup/readiness and poll
  time, so it understates steady-state throughput:

  | source | persisted rows/s | JetStream messages/s | rows | messages | payload bytes | publish wall time |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | `generic` | 6,445 | 6 | 75,000 | 75 | 18,432,085 | 11.5 ms |
  | `generic` | 3,067 | 12 | 3,000 | 12 | 737,491 | 2.7 ms |

  The second row is a 2026-06-14 small end-to-end smoke using a fresh migrated `srql-fixtures`
  scratch CNPG database and local JetStream. It waited for all 3,000 expected rows, reported
  `failed_series=0`, and the scratch database was verified absent from the CNPG primary after the
  cleanup trap ran.

  The pipeline run is lower than the direct processor persistence run because it includes EventWriter
  producer startup/readiness, JetStream delivery, Broadway batching, ack handling, table-count polling, and
  the same shared CNPG NodePort persistence path. It also validates the important correctness property for
  this cutover: the row count reached the expected value, so the protobuf identity fields did not collapse
  distinct series under the migrated `(timestamp, gateway_id, series_key)` key.

  These pipeline numbers validate the end-to-end PATH and the relative cost ordering of the stages; they are
  NOT a production-representative absolute-throughput measurement. They were taken on a local single-node
  `nats-server -js` plus a NodePort scratch CNPG, and the rate includes producer startup/poll time.
  Production-representative absolute throughput — clustered NATS, production CNPG, and sustained fan-in — is
  still UNPROVEN and is the real gate.

  Final 5.3 readout: the protobuf path materially improves the fair JSON baselines for the two axes that
  still have a meaningful side-by-side comparison after the hard cutover: decode/row-shaping and the measured
  anomaly sample-extraction stage. The extraction fixture wall-clock still needs to be read with the payload
  construction caveat above. The runtime no longer has JSON metric publishers, JSON-first EventWriter metric decode,
  or JSON-first anomaly metric extraction to compare in the broker/persistence path. The remaining
  environment-backed bottleneck is CNPG/Timescale insertion and Broadway/JetStream delivery; the pipeline
  run above validates that end-to-end path and the relative cost ordering of its stages, but its absolute
  rate was measured on a local single-node NATS + NodePort scratch CNPG and includes producer startup/poll
  time, so it is not a production-representative absolute-throughput number. Production-representative
  absolute throughput (clustered NATS, production CNPG, sustained fan-in) remains UNPROVEN and is the real
  gate — not a JSON-vs-protobuf decoder comparison.

### Decision 7: Observability for the decode boundary
Match the conventions in `telemetry.ex` and the `Telemetry.Metrics` registry: (1) a decode-failure counter
tagged `[:reason]` (mirroring `spiffe.verification.failure` / `otlp_relay.record_rejected`), sourced from
the currently-swallowed `Logger.debug` failure sites; (2) a `schema_version` distribution signal
(today only state_change/causal_signals stamp a schema_version — metric/otel payloads carry none);
(3) reuse `SignalTelemetry` received/written/rejected for batch throughput + drops; (4) close the existing
gap where the anomaly Pipeline's `[:serviceradar, :anomaly_detection, :consumer, *]` events are emitted but
not registered in `*_metrics/0`; (5) an envelope decode/extract latency distribution. All new metrics go
into a `*_metrics/0` list concatenated by `Telemetry.metrics/0` so they reach Prometheus/LiveDashboard.

## Risks / Trade-offs
- Risk: hard cutover means a single broken producer/consumer pair breaks ingestion. → Mitigation: the
  shadow/parity gate + a clean single-commit rollback; no users to impact.
- Risk: untrusted producer-set kind/source mis-routes metrics. → Mitigation: gateway attestation (Decision 3).
- Risk: schema drift between the proto and cadence Decision 0 field contract. → Mitigation: the proto
  reuses the cadence field set verbatim; a parity test asserts no field is dropped.
- Risk: protobuf field-number churn during authoring. → Mitigation: reserve numbers; additive-only evolution.

## Migration Plan
1. Define `proto/metric/v1/metric.proto`; generate Go/Rust/Elixir codecs with the repo's existing
   proto/Bazel/Cargo/Mix generation paths.
2. Land producer emit (Go agents + Go/Rust/wasm SDKs, including ICMP checks and native add-on `StreamTelemetry` helpers)
   and consumer decode (EventWriter Metrics, anomaly SampleExtractor, causal-engine) behind the new
   envelope, NOT yet wired as the publisher default.
3. Run the shadow/parity gate (Decision 5) and the benchmark gate (Decision 6); capture the JSON baseline.
4. Single cutover commit: switch all publishers to protobuf, delete the JSON publishers + JSON-first decode
   branches + the cadence legacy-gauge clause; add the decode observability.
5. Rollback = revert the cutover commit/tag.

## Resolved Implementation Guidance
- Use ServiceRadar-local enums for `kind`, `temporality`, and unit semantics, with an explicit OTLP mapping.
  Mirroring OTLP names is useful, but importing OTLP enum values directly would couple SNMP/sysmon/plugin
  semantics to an external transport model and make future SR-only metric classes awkward.
- Use a batch wrapper per NATS message. The wrapper carries shared schema version, producer/gateway
  attestation, resource identity, and repeated metric envelopes/points. A one-point metric is represented
  as a batch of one. Bound batches by count and bytes so `Nats-Msg-Id` idempotency remains clear and NATS
  message size stays comfortably below the stream limit.
- Derive the authoritative `series_identity` at the gateway/consumer from typed resource + metric +
  attributes using one versioned algorithm. Producers may include a non-authoritative hint for debugging
  or migration parity, but consumers must not trust a producer-supplied series key as canonical identity.

## Dependency Coordination
- `add-monotonic-counter-metric-semantics`: the protobuf contract carries the fields that change requires
  without a second migration path: `Metric.kind`, `Metric.temporality`, `Metric.is_monotonic`,
  `Metric.counter_width`, `MetricPoint.raw_value`, `MetricPoint.raw_value_type`,
  `MetricPoint.start_time_unix_nano`, and `MetricPoint.reset_anchor`. EventWriter and anomaly extraction
  both copy those typed fields into persisted/sample metadata so the counter normalizer can use raw
  cumulative values and reset anchors instead of treating ramps as gauges.
- `add-cgroup-v2-tenant-metrics`: cgroup metrics stay on the same `serviceradar.metric.v1` envelope and
  `metrics.*` stream. The attested host remains in `MetricResource`; cgroup path, slice, tenant/account,
  container, and Kubernetes labels fit in `MetricPoint.attributes` or metric tags. Per-cgroup reset
  lineage uses `MetricPoint.reset_anchor`, so cgroup recreation does not require a cgroup-specific stream,
  table, or producer-specific UI path.

## Current Verification Notes
- `go test -count=1 ./go/pkg/agent ./go/pkg/addon/sdk` passes in the main repo. This covers the Go agent
  metric envelope producers, plugin telemetry metric payload validation, native add-on telemetry bridge, and
  the in-repo Go native add-on SDK helper. Native add-ons are explicitly in scope for this cutover: the agent
  bridge test now uses `go/pkg/addon/sdk.ServiceRadarMetricRecord` to prove the SDK-authored `StreamTelemetry`
  metric payload is preserved by the agent, attested by the gateway, published to the same `metrics.*`
  JetStream path, and decoded as the same canonical `serviceradar.metric.v1.MetricBatch` shape as
  sysmon/SNMP/plugin metrics. The sysmon push loop now batches drained samples into bounded protobuf
  `MetricBatch` status payloads instead of emitting one gateway stream chunk per sample, reducing edge
  transport overhead while preserving per-point observed timestamps.
- `go test -count=1 ./go/pkg/models ./go/pkg/agent ./go/pkg/addon/sdk` passes after removing unused exported
  Go model structs that advertised old JSON metric payload contracts (`ServiceMetricsPayload`,
  `SNMPMetricsPayload`, `SNMPMetric`, and the unused RPerf metric response models). Runtime metric producers
  and consumers now point at the protobuf envelope instead of stale JSON model types.
- `go test -count=1 ./go/pkg/swagger ./go/pkg/models ./go/pkg/addon/sdk ./go/pkg/agent` passes after
  pruning the embedded Swagger artifacts that still referenced deleted `models.SNMPMetric` and
  `models.RperfMetric` schemas. The historical agent metric-buffering OpenSpec note now points at
  `serviceradar.metric.v1.MetricBatch` plus JetStream/EventWriter, rather than a JSON metric envelope or
  direct backend time-series write.
- `cargo test --manifest-path rust/rperf-client/Cargo.toml` passes after removing dead JSON result construction
  from the rperf AgentService metric hot path. When rperf samples are available, the service now collects
  samples and returns the encoded `serviceradar.metric.v1.MetricBatch` without first allocating an unused
  JSON `results` array; JSON remains only for the no-metric health/status fallback.
- `go test -count=1 ./go/pkg/agent/snmp ./go/pkg/agent` passes with a regression covering the lower-level
  SNMP checker/gRPC status responses. Those responses now expose only target health/read-model summaries and
  cannot serialize `oid_status`, `last_value`, or raw OID samples as a shadow JSON metric channel.
- `cargo test --manifest-path rust/addon-sdk/Cargo.toml` passes in the main repo, covering the in-repo Rust
  native add-on SDK helper that wraps an encoded `serviceradar.metric.v1.MetricBatch`. `cargo test
  --manifest-path rust/metric-proto/Cargo.toml` also passes, covering the shared Rust protobuf crate's
  gauge/cumulative-counter round trip.
- `go test ./...` passes in `/Users/mfreeman/src/serviceradar-sdk-go`; `cargo test` passes 90 tests in
  `/Users/mfreeman/src/serviceradar-sdk-rust`. Those standalone SDK repos no longer serialize time-series
  metrics into `serviceradar.plugin_result.v1`; metric authors use first-class MetricBatch telemetry helpers.
  A fresh SDK audit found the remaining `metrics` JSON references are absence/rejection tests or docs that
  point authors to `serviceradar.metric.v1` telemetry; no standalone SDK helper still emits
  `plugin_result.metrics[]`.
- Gateway-focused Elixir verification passes with 56 tests across `status_processor_test.exs`, all
  `*_metrics_publisher_test.exs`, `plugin_metrics_publisher_test.exs`, `stream_status_limits_test.exs`, and
  `telemetry_test.exs`. That suite proves metric-only statuses publish through the gateway-owned JetStream
  path, do not forward to core, and return publish errors instead of acknowledging undelivered metrics.
  An additional status-processor regression now runs the real metric publisher modules for sysmon, SNMP,
  ICMP, rperf, MTR, and sweep with enabled configs and JSON-shaped metric bodies; each source fails with
  `:invalid_metric_batch_payload` and never forwards to core.
- A current gateway-focused rerun passes 55 tests across `status_processor_test.exs`,
  `stream_status_limits_test.exs`, and the sysmon/SNMP/ICMP/rperf/MTR/sweep/plugin metric publisher suites.
  This includes the hard-cutover checks that reject legacy JSON metric payloads and publish only decoded
  `serviceradar.metric.v1.MetricBatch` payloads to `metrics.*`.
- Core-focused Elixir verification passes with 75 tests across EventWriter metric processors, OTLP-derived
  metric decoding, anomaly `SampleExtractor`, `ResultsRouter`, `StatusHandler`, and telemetry registration.
  Local runs without localhost CNPG log expected service-state connection warnings, but the tested metric
  hard-cutover paths pass.
- A current core-focused rerun passes 57 tests across EventWriter metric processors, OTLP-derived metric
  decoding, anomaly `SampleExtractor`, `StatusHandler`, and `ResultsRouter`. Local runs without localhost CNPG
  continue to log expected service-state connection warnings from result-router side effects, but the metric
  hard-cutover paths pass, including rejecting gateway metric statuses from direct core routing.
- A current 1k-series all-source in-memory smoke matrix passes for `generic`, `sysmon`, `snmp`, `icmp`,
  `mtr`, `sweep`, `rperf`, `plugin`, `addon`, and `otel_derived` using both
  `metric_envelope_eventwriter_rows` and `metric_envelope_extract`. Each source/mode pair processed
  3,000 rows or samples across 12 decoded messages with zero failed series. This smoke verifies the source
  selector and typed protobuf row/sample paths for every supported producer shape, including native add-on
  and OTLP-derived profiles. The native add-on profile processed 3,000 protobuf rows at 112,537 rows/s for
  EventWriter row-build and 3,000 protobuf samples at 138,549 samples/s for anomaly extraction, using the
  richer `AddonService.StreamTelemetry`-shaped payload with 1,248,666 bytes across 12 messages.
- A fresh scratch-CNPG persistence smoke run also passes for
  `metric_envelope_eventwriter_persist` after the benchmark harness was corrected to start the repo pool
  under the documented `mix run --no-start` invocation. The 1k-series generic run inserted 3,000
  `platform.timeseries_metrics` rows from 12 protobuf metric messages with zero failed series, measured
  2,989 persisted rows/s through the remote `srql-fixtures` CNPG NodePort, and confirmed persistence was
  dominated by database insert latency rather than protobuf decoding.
- A current generic 5k-series protobuf-vs-benchmark-only-JSON comparison with 75,000 rows/samples keeps the
  expected direction on the reliable axes: protobuf payload bytes were 14,175,085 vs JSON 32,751,110
  (~56.7% smaller), decode stage work was 4,872 ns/row vs 5,961 ns/row, and anomaly extraction stage work was
  4,563 ns/sample vs 6,175 ns/sample. Protobuf extraction also won the short wall sample in this rerun
  (0.186s / 402,957 samples/s vs 0.194s / 387,329 samples/s) and used less post-run memory delta
  (2.62 MB vs 10.54 MB). The short decode wall sample favored JSON despite worse timed stage work
  (0.195s JSON vs 0.218s protobuf), so the benchmark claim remains scoped to payload bytes, summed stage work,
  and production extraction/row-build behavior. EventWriter protobuf row-build measured 4,012 ns/row
  (0.176s / 427,275 rows/s). Runtime JSON metric paths are removed rather than retained.
- A follow-up protobuf hot-path cleanup removed nested row-list construction, skipped empty protobuf-entry map
  merges, and replaced per-sample list-based hash input construction with direct iodata hashing. On the same
  5k-series/75,000-row short generic harness, EventWriter protobuf row-build improved from the current
  pre-cleanup sample of 4,848 ns/row (0.211s / 354,778 rows/s) to a conservative post-cleanup sample of
  4,413 ns/row (0.195s / 385,180 rows/s), and anomaly protobuf extraction improved from 7,883 ns/sample
  (0.325s / 230,607 samples/s) to 5,512 ns/sample (0.227s / 330,920 samples/s). These are short-run local
  numbers, and repeated runs were noisy, but they keep the typed protobuf path moving in the intended
  direction by cutting BEAM allocation work rather than adding compatibility branches.
- The high-rate EventWriter metrics processor now uses `MetricEnvelope.decode_rows_count/1`, which returns
  the row count accumulated during protobuf row construction instead of traversing the completed row list
  with `length/1` for telemetry. On the native-add-on-shaped 5k-series/75,000-row smoke, EventWriter
  protobuf row-build improved from 8,234.5 ns/row (227,954 rows/s) to 7,823.9 ns/row (236,944 rows/s).
  The post-run memory delta was noisy and higher in that short sample (2.53 MB to 4.09 MB), so this only
  claims a timed row-build improvement.
- A native-add-on-shaped extraction rerun using the documented `mix run --no-start` path confirms the
  `AddonService.StreamTelemetry` profile stays on the typed protobuf path. After removing one per-point
  `Map.merge/2` from typed sample extraction, `metric_envelope_extract` on
  `ANOMALY_BENCH_METRIC_SOURCE=addon` improved from 190,581 to 204,366 samples/s on the 5k-series/75k-sample
  smoke, and post-run memory delta dropped from 4.74 MB to 2.50 MB with the same 29.94 MB payload. A later
  benchmark-only legacy JSON fixture won one short wall-clock sample at 387,071 samples/s, but that fixture
  is not a retained runtime path and is simpler than the old multi-hop JSON chain. The claim for this source
  is therefore payload/memory reduction plus hard-cutover removal of JSON metric runtime paths, not an
  unconditional wall-clock win against the synthetic JSON fixture.
- First-party wasm plugin metric telemetry checks pass for Proxmox and UniFi Protect with
  `go test -count=1 ./...` from each plugin module. AXIS metric/result tests pass with
  `go test -count=1 -run 'TestEncodeMetricBatchProducesCanonicalMetricEnvelope|Test.*Metric|Test.*Result|Test.*Legacy|Test.*Health' ./...`;
  the full AXIS module run additionally requires `wasm-opt` for its TinyGo compatibility test, which was not
  installed in the local verification environment.
- Core hard-cutover checks pass with
  `mix test test/serviceradar/status_handler_test.exs test/serviceradar/results_router_test.exs`. Stale
  `sysmon-metrics`, `snmp-metrics`, `icmp-metrics`, `rperf-metrics`, `mtr-metrics`, and `sweep-metrics`
  statuses are rejected by `StatusHandler` before `ResultsRouter` forwarding, and `ResultsRouter` still
  rejects those sources defensively if called directly, so they cannot silently fall through as legacy
  direct-to-core metric ingestion.
- A runtime JSON audit of metric-adjacent code paths distinguishes the remaining intentional JSON contracts
  from forbidden metric envelopes. Sysmon and SNMP regular statuses carry only health/read-model summaries;
  configured ICMP checks emit protobuf `icmp-metrics` statuses and core rejects direct `icmp-metrics`
  routing; MTR and sweep still publish JSON domain/result payloads for `mtr_traces`/`mtr_hops` and sweep
  execution persistence, while their scalar time-series summaries are emitted as separate protobuf metric
  statuses; wasm plugin telemetry keeps a JSON host ABI wrapper only to carry base64-encoded protobuf bytes
  because the sandbox ABI is JSON, and the agent decodes that wrapper back to raw `MetricBatch` bytes before
  forwarding. No runtime metric publisher or metric consumer found in this audit accepts a per-source JSON
  metric envelope or `plugin_result.metrics[]` compatibility path.
- The stale-looking `MtrMetricsIngestor` name was audited during the protobuf hard-cutover work. Despite the
  name, it persists MTR trace and hop domain rows into `mtr_traces` and `mtr_hops` and projects MTR graph
  edges; it does not persist scalar samples into `timeseries_metrics` or feed anomaly detection. MTR scalar
  availability, hop, latency, loss, and jitter summaries remain covered by the protobuf `mtr-metrics`
  `MetricBatch` publisher.

## Decision: defer sysmon per-process detail (follow-up)
The hard cutover emits collapsed sysmon gauges (cpu/memory/disk used_percent, process.count) through the
canonical envelope into `timeseries_metrics`. The deleted `SysmonMetricsIngestor` previously wrote rich
per-entity rows (per-PID `ProcessMetric`, per-core `CpuMetric`, per-mount `DiskMetric`, `MemoryMetric`) to
typed hypertables, which now have no writer. Restoring per-process detail (either a typed per-process writer
or migrating the web-ng sysmon dashboards to `timeseries_metrics` aggregates) is explicitly DEFERRED to a
follow-up change: it is not part of what this release validates (the anomaly engine + canonical envelope),
the typed tables degrade gracefully (SRQL `in:process_metrics` returns empty, no crash), and emitting
per-PID points must NOT create per-PID anomaly series. Aggregate sysmon gauges are the shipped contract.

## Benchmark note: protobuf vs detector eval/s (do not conflate)
Measured on this workstation profile (single core): protobuf is a decode (~-35%), extraction (~-19%), and
payload (~-57%) win, NOT a detector eval/s win — eval/s is downstream of decode and protobuf does not touch
it. Detector throughput by path: pure detector (`native_engine_prepared_shards`, GenServer-bypass) ~993k
eval/s; production sharded `handle_call` (`sharded_engine_events`) ~601k eval/s; production native
(`native_engine_events`, full wrapper) ~225k eval/s. The gap below the detector ceiling is the production
wrapper (checkpoint `queue_series`, telemetry, eviction, seen-events dedup) added by the engine hardening,
not the DeepCausality math. Per-core × shard count still far exceeds the realistic workload (~85–330k
eval/s total at competitor cadence), so this does not block the release; the sharded engine is the faster
scale path (~2.7× the native path), and recovering the ~1.3M/core hope is a later wrapper-trimming pass.
