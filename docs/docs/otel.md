---
title: OTEL Ingest Guide
---

# OTEL Ingest Guide

ServiceRadar ingests OpenTelemetry traces, logs, and metrics over OTLP. This page is the
onboarding guide for external producers: where to point your exporter, how TLS and client
authentication work, per-language quickstarts, how to verify that telemetry landed, and how
to query and correlate it afterwards.

The OTLP receiver is the embedded OTEL collector (`rust/otel`) running inside the
`serviceradar-log-collector` service. It accepts OTLP exports, publishes them to NATS
JetStream (stream `events`), and the event writer persists them into CNPG/TimescaleDB
tables that SRQL and the web UI query.

## Endpoints at a glance

| Deployment | OTLP/gRPC (4317) | OTLP/HTTP (4318) | Server TLS | Client certificate |
|---|---|---|---|---|
| Kubernetes, external via shared gateway (recommended; demo runs this) | `<grpc-hostname>:50052` TLS passthrough through the shared Envoy gateway (demo: `otlp-demo.grpc.serviceradar.cloud:50052`) | `https://<http-hostname>` (port 443) terminated by the gateway with a publicly trusted certificate (demo: `https://otlp-demo.serviceradar.cloud`) — no CA download needed; this is the easiest external path | gRPC: ServiceRadar private CA (passthrough). HTTP: public certificate at the gateway | Not requested |
| Kubernetes, external via LoadBalancer (opt-in: `logCollector.otlp.service.type=LoadBalancer`) | `<LB-IP>:4317` via the `serviceradar-otlp` Service | Published after `logCollector.otlp.service.http.enabled=true` | Yes, cert issued by the ServiceRadar private CA | Not requested (chart config sets no client CA) |
| Kubernetes, in-cluster | `serviceradar-log-collector:4317` | Pod port 4318 (no Service port by default) | Yes, same CA | Not requested |
| Docker Compose | `localhost:4317` (published on the host) | Not published by default; add a `4318:4318` port mapping | Yes, local dev CA | Required by default (`client_auth` defaults to `required`); see the override below |

### OTLP/gRPC (port 4317)

- Accepts `gzip` and `zstd` compressed export requests and compresses responses with gzip
  when the client advertises support. (OTel SDKs and the OpenTelemetry Collector negotiate
  gzip by default; collector builds older than this feature answer those exports with
  `UNIMPLEMENTED`.)
- Maximum decoded request size: `[server] max_request_bytes`, default 64 MiB (67108864).
- Oversized individual records do not fail the export: the response carries OTLP
  `partial_success` with `rejected_spans` / `rejected_data_points` / `rejected_log_records`
  and an error message. Watch your SDK logs for partial-success warnings.

### OTLP/HTTP (port 4318)

- Enabled by default (`[server.http] enabled = true`). Standard OTLP paths:
  `POST /v1/traces`, `POST /v1/logs`, `POST /v1/metrics`.
- Request encoding: binary protobuf (`Content-Type: application/x-protobuf`;
  `application/protobuf` is also accepted), optionally with `Content-Encoding: gzip`.
- OTLP/JSON is intentionally not supported. JSON requests receive HTTP 415 with the
  message: `OTLP/JSON is not supported; send binary OTLP protobuf (Content-Type:
  application/x-protobuf) or use OTLP/gRPC on the gRPC port`.
- Serves HTTPS whenever `[grpc_tls]` is configured (it reuses the gRPC server
  certificate); plaintext otherwise. The HTTP listener never requests client
  certificates, regardless of the `client_auth` setting.
- CORS for browser-based exporters: `allowed_origins` defaults to `["*"]`. Restrict it
  when the listener is reachable from the public internet.
- The same `max_request_bytes` cap applies to the (decompressed) HTTP body.

### Collector configuration reference (`otel.toml`)

```toml
[server]
bind_address = "0.0.0.0"
port = 4317
max_request_bytes = 67108864   # 64 MiB default

[server.http]
enabled = true                 # default
bind_address = "0.0.0.0"
port = 4318
allowed_origins = ["*"]        # restrict for public exposure

[grpc_tls]
cert_file = "/etc/serviceradar/certs/log-collector.pem"
key_file = "/etc/serviceradar/certs/log-collector-key.pem"
# ca_file is only needed when you want client-certificate auth:
# ca_file = "/etc/serviceradar/certs/root.pem"
# client_auth = "required"     # required | optional | none (default: required)
```

## TLS and authentication

The collector presents a server certificate issued by the ServiceRadar private CA.
External senders must do one of:

1. Trust the ServiceRadar root CA bundle (recommended; see below for where to get it).
2. Disable certificate verification in the exporter (quick tests only).
3. Put the OTLP endpoint behind their own TLS termination (ingress/LB with a public
   certificate) and forward to the collector.

### Getting the root CA bundle

Kubernetes - the runtime certificates live in the `serviceradar-runtime-certs` secret
(key `root.pem`):

```bash
kubectl -n <namespace> get secret serviceradar-runtime-certs \
  -o jsonpath='{.data.root\.pem}' | base64 -d > serviceradar-root.pem
```

Docker Compose - certificates are generated into the `cert-data` volume:

```bash
mkdir -p .local-dev-certs
sudo cp /var/lib/docker/volumes/serviceradar_cert-data/_data/root.pem .local-dev-certs/
sudo chown -R "$USER" .local-dev-certs
```

(`.local-dev-certs/` is already in `.gitignore`.)

### Client certificates: `client_auth`

The gRPC listener's client-certificate policy is set by `client_auth` under `[grpc_tls]`:

| Mode | Behavior |
|---|---|
| `required` (default) | Clients must present a certificate signed by `ca_file` (strict mTLS). |
| `optional` | Certificates are verified when presented, but connections without one are accepted. Use this when one listener serves both internal mTLS clients and external producers. |
| `none` | Client certificates are never requested, even if `ca_file` is set. Server-side TLS only. |

Notes:

- `required`/`optional` only take effect when `ca_file` is set. With no `ca_file` there is
  nothing to verify against, so client certificates are not requested (the collector logs
  a warning if you asked for `required` without a CA).
- Operators exposing external ingest should use `optional` or `none`.
- The Helm chart's generated `otel.toml` configures `[grpc_tls]` with the server cert and
  key only (no `ca_file`), so Kubernetes deployments do not request client certificates:
  external senders only need to trust the server CA.

### Docker Compose: relaxing the default mTLS

The shipped compose config (`docker/compose/otel.docker.toml`) sets `ca_file` without
`client_auth`, which means `required`: plain `grpcurl`/SDK clients are rejected during the
TLS handshake on `localhost:4317`. For local development either:

- present the workstation client pair from `.local-dev-certs/` (`workstation.pem` /
  `workstation-key.pem`, e.g. `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE` /
  `OTEL_EXPORTER_OTLP_CLIENT_KEY`), or
- relax the listener by editing `docker/compose/otel.docker.toml`:

```toml
[grpc_tls]
cert_file = "/etc/serviceradar/certs/log-collector.pem"
key_file = "/etc/serviceradar/certs/log-collector-key.pem"
ca_file = "/etc/serviceradar/certs/root.pem"
client_auth = "none"   # or "optional"
```

then `docker compose restart log-collector`.

To use OTLP/HTTP from the host, also add `- "4318:4318"` to the `log-collector` service
ports in `docker-compose.yml`. The HTTP listener uses the same server certificate and
never requires a client certificate.

### Ingestion tokens

Bearer-token authentication for external producers is coming but is not implemented yet.
Today the available controls are server TLS, `client_auth`, and network policy.

## Exposing the endpoint in Kubernetes

The chart ships a dedicated `serviceradar-otlp` Service (default-on) that fronts the
log-collector pods for external ingest:

Two exposure modes exist; the shared-gateway mode is preferred because it reuses
the platform's existing public IP and (for OTLP/HTTP) its publicly trusted
certificate.

**Gateway mode (recommended — demo runs this).** Attaches an HTTPRoute (OTLP/HTTP,
terminated at the gateway with the public wildcard cert) and a TLSRoute
(OTLP/gRPC, TLS passthrough to the collector) to the shared Envoy gateway:

```yaml
logCollector:
  otlp:
    service:
      enabled: true
      type: ClusterIP             # gateway routes target the ClusterIP Service
      http:
        enabled: true             # publish 4318 for the HTTPRoute backend
        tlsEnabled: false         # gateway terminates public TLS; in-cluster hop is plain
    gateway:
      enabled: true
      httpHostname: otlp-demo.serviceradar.cloud        # one label under the wildcard
      grpcHostname: otlp-demo.grpc.serviceradar.cloud   # tls-grpc listener, port 50052
```

  Wildcard listeners match a single DNS label (`otlp-demo.serviceradar.cloud`, not
  `otlp.demo.serviceradar.cloud`). external-dns auto-provisions the HTTPRoute
  hostname; TLSRoute hostnames are not watched by the current external-dns config
  and need a manual record (or `--source=gateway-tlsroute`) pointing at the
  gateway address. A scoped NetworkPolicy admits only the Envoy gateway namespace
  to 4317/4318 in this mode.

**LoadBalancer mode (opt-in)** for clusters without the shared gateway:

```yaml
logCollector:
  otlp:
    service:
      enabled: true
      type: LoadBalancer          # opt-in; consumes a public IP
      externalTrafficPolicy: Cluster   # set Local to preserve client source IPs
      annotations: {}             # e.g. metallb.universe.tf/address-pool: k3s-pool
      loadBalancerIP: ""          # optional static IP
      http:
        enabled: false            # set true to also publish OTLP/HTTP 4318
```

  In LB mode a CIDR-scoped NetworkPolicy gates ingress instead:

```yaml
networkPolicy:
  ingress:
    otlpExternal:
      enabled: true
      allowedCIDRs:
        - "0.0.0.0/0"             # tighten to your producers' networks
```

- In-cluster producers should skip both and send to
  `serviceradar-log-collector:4317`.

## Quickstarts

Replace `<otlp-host>` with the gateway hostname (external; for http/protobuf use
`https://otlp-demo.serviceradar.cloud` — no CA needed), the opt-in LoadBalancer IP,
`serviceradar-log-collector` (in-cluster), or `localhost` (compose). The snippets assume you downloaded the CA bundle
as `serviceradar-root.pem` (see above). Skip-verify variants are shown for quick tests
only; do not use them in production.

### OpenTelemetry Collector (recommended for fleets)

```yaml
exporters:
  # OTLP/gRPC
  otlp/serviceradar:
    endpoint: <otlp-host>:4317
    compression: gzip            # zstd also accepted
    tls:
      ca_file: /etc/otelcol/serviceradar-root.pem
      # or, for quick tests only:
      # insecure_skip_verify: true

  # OTLP/HTTP (binary protobuf; do not set encoding: json)
  otlphttp/serviceradar:
    endpoint: https://<otlp-host>:4318
    compression: gzip
    tls:
      ca_file: /etc/otelcol/serviceradar-root.pem

service:
  pipelines:
    traces:
      exporters: [otlp/serviceradar]
    metrics:
      exporters: [otlp/serviceradar]
    logs:
      exporters: [otlp/serviceradar]
```

### Java (auto-instrumentation agent)

gRPC:

```bash
export OTEL_SERVICE_NAME=checkout
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4317
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem
java -javaagent:opentelemetry-javaagent.jar -jar app.jar
```

HTTP/protobuf:

```bash
export OTEL_SERVICE_NAME=checkout
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4318
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem
java -javaagent:opentelemetry-javaagent.jar -jar app.jar
```

There is no standard env var for skip-verify in the Java agent; trust the CA bundle.

### Python

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
```

gRPC:

```bash
export OTEL_SERVICE_NAME=checkout
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4317
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem
opentelemetry-instrument python app.py
```

HTTP/protobuf:

```bash
export OTEL_SERVICE_NAME=checkout
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4318
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem
opentelemetry-instrument python app.py
```

### Node.js

```bash
npm install @opentelemetry/api @opentelemetry/auto-instrumentations-node
```

gRPC:

```bash
export OTEL_SERVICE_NAME=checkout
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4317
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem
node --require @opentelemetry/auto-instrumentations-node/register app.js
```

HTTP/protobuf (the Node SDK default protocol):

```bash
export OTEL_SERVICE_NAME=checkout
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4318
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem
node --require @opentelemetry/auto-instrumentations-node/register app.js
```

### Go

The Go OTLP exporters honor the same standard env vars, so the code stays minimal.

gRPC:

```bash
export OTEL_SERVICE_NAME=checkout
export OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4317
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/serviceradar-root.pem
```

```go
import (
    "context"

    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

exp, err := otlptracegrpc.New(context.Background())
if err != nil { /* handle */ }
tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
```

HTTP/protobuf: set `OTEL_EXPORTER_OTLP_ENDPOINT=https://<otlp-host>:4318` and swap the
exporter for `otlptracehttp.New(context.Background())` from
`go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp`.

### Quick smoke test with telemetrygen

```bash
docker run --rm ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-endpoint <otlp-host>:4317 --otlp-insecure-skip-verify \
  --traces 5 --child-spans 3 --status-code Error --service smoke-test
```

For a full traces+logs+metrics round trip with database verification, use the
conformance harness below.

## Verifying ingest: scripts/otel-conformance.sh

The repo ships a conformance harness that sends a known workload through telemetrygen
(5 error traces with 3 child spans each, 10 log records, 6 Sum metric data points named
`gen`) and verifies every signal landed in CNPG:

```bash
# Print the verification SQL only (no database access):
OTLP_ENDPOINT=otlp-demo.grpc.serviceradar.cloud:50052 TG_FLAGS="--otlp-insecure-skip-verify" \
  ./scripts/otel-conformance.sh

# Run end to end, including SQL verification against CNPG:
OTLP_ENDPOINT=otlp-demo.grpc.serviceradar.cloud:50052 TG_FLAGS="--otlp-insecure-skip-verify" \
  PSQL_DSN="postgres://serviceradar:***@<db-host>:5432/serviceradar" \
  ./scripts/otel-conformance.sh

# Inside a cluster without docker, run telemetrygen via kubectl run:
OTLP_ENDPOINT=serviceradar-log-collector:4317 TG_FLAGS="--otlp-insecure-skip-verify" \
  ./scripts/otel-conformance.sh --kubectl
```

When `PSQL_DSN` is set the script polls for the [maintained storage outputs](#storage-model) and
exits nonzero if any of these checks stays at zero: span count and distinct trace count in
`otel_traces`, summed `span_count` in `otel_trace_summaries`, row count in `logs`, and
`metric_name = 'gen'` rows in `otel_metric_points` for the generated service name.

## Storage model

All tables live in CNPG (TimescaleDB hypertables). Retention is enforced by the daily
`DataRetentionWorker` (03:17); defaults below are per-deployment configurable.

| Table | Contents | Default retention |
|---|---|---|
| `otel_traces` | One row per span (`trace_id`, `span_id`, `parent_span_id`, timing, status, attributes) | 3 days |
| `otel_trace_summaries` | One row per trace: root span, `span_count`, `error_count`, `duration_ms`, `service_set`. Maintained by an incremental worker | 3 days |
| `otel_metrics` | Span-derived performance samples from `otel.metrics.derived` protobuf MetricBatch payloads (spans slower than 100 ms are flagged `is_slow`) | 30 days |
| `otel_metric_points` | OTLP metric data points: Sums, Gauges, Histograms, keyed by `(timestamp, metric_name, service_name, attributes_hash)`. Exponential histograms and summaries are counted in pipeline accounting but not yet decoded (spec'd follow-up) | 30 days |
| `logs` | OTLP logs and syslog/GELF, with `trace_id`/`span_id` when the SDK provides them | 30 days |

Successful nonempty span writes request an immediate Oban summary refresh. Pending
requests are coalesced, and ingest during an executing refresh can queue a follow-up.
Refreshes are serialized with a transaction-scoped advisory lock; a competing worker
snoozes and retries. After commit, changed summaries trigger a Live UI refresh.
The default two-minute cron remains a fallback. Summary visibility depends on worker
availability and completion, rather than requiring a cron tick for every batch.

Canonical identifier contract: `trace_id` is stored as 32-character lowercase hex and
`span_id`/`parent_span_id` as 16-character lowercase hex in every table (absent or
all-zero IDs become NULL). This makes correlation a plain equality join - no casts, no
normalization at query time.

## Correlation and query recipes

Trace detail UI: `/observability/traces/<trace_id>` renders the span tree with
correlated logs. The logs and metrics views link through to it wherever a record carries
a trace ID.

SRQL recipes:

```text
# All spans of one trace, in start order
in:traces trace_id:"4bf92f3577b34da6a3ce929d0e0e4736" sort:start_time_unix_nano:asc

# Logs correlated with the same trace
in:logs trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"

# Metric points for one metric over the last hour
in:otel_metric_points metric_name:"gen" time:last_1h

# RED (rate / errors / duration) rollup for traces, optionally per service
in:traces rollup_stats:red time:last_1h
in:traces service_name:"checkout" rollup_stats:red time:last_1h

# Per-trace summaries and log severity rollups
in:trace_summaries time:last_1h
in:logs rollup_stats:severity time:last_24h
```

Equivalent ad-hoc SQL (e.g. from the `serviceradar-tools` pod):

```sql
SELECT l.timestamp, l.severity_text, l.body
FROM logs l
JOIN otel_traces t USING (trace_id)
WHERE t.service_name = 'checkout'
  AND t.timestamp > now() - INTERVAL '1 hour';
```

## Collector internals (for operators)

- The OTEL collector is not a standalone service: it runs embedded in
  `serviceradar-log-collector`, which supervises a flowgger (syslog/GELF) input and the
  OTEL input from one deployment. The `[otel]` block in `log-collector.toml` enables it
  and points at `otel.toml`; a unified health server listens on `:50044`.
- Telemetry is published to NATS JetStream stream `events`: raw spans on
  `otel.traces.raw`, raw metric points on `otel.metrics.raw`, span-derived performance
  samples as `serviceradar.metric.v1.MetricBatch` protobuf payloads on
  `otel.metrics.derived`, and OTLP logs on `logs.otel`. The event writer consumes these
  subjects and writes the tables above.
- The collector exposes its own operational metrics over a small HTTP server, separate
  from the OTLP listeners: `GET /metrics` (Prometheus exposition) and `GET /health`
  (liveness). The dev `otel.toml` binds it on `0.0.0.0:9464` via `[server.metrics]`; if
  the section is omitted (as in the packaged config) the metrics server is not started,
  and the built-in default port is 9090 when the section is present without a port.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| gRPC export fails with `UNIMPLEMENTED` (grpc-status 12) | Collector build predates gzip/zstd request compression support; OTel SDKs negotiate gzip by default | Upgrade `serviceradar-log-collector`. Workaround: set exporter compression to `none` |
| HTTP 415 `OTLP/JSON is not supported ...` | Exporter is sending OTLP/JSON (`http/json` protocol or collector `otlphttp` with `encoding: json`) | Switch to `http/protobuf` or OTLP/gRPC |
| `certificate verify failed` / `x509: certificate signed by unknown authority` | The server certificate is issued by the ServiceRadar private CA | Point the exporter at the root CA bundle (`OTEL_EXPORTER_OTLP_CERTIFICATE`, collector `tls.ca_file`), use skip-verify for quick tests, or terminate TLS yourself in front of the collector |
| Connection refused on 4318 | Old collector build without the OTLP/HTTP listener; or compose without a `4318:4318` mapping; or the k8s Service has `logCollector.otlp.service.http.enabled=false` | Upgrade the collector, publish the port, or enable the Service port |
| TLS handshake rejected on compose `localhost:4317` (e.g. `certificate required`) | Compose ships `[grpc_tls]` with a CA and the default `client_auth = "required"` | Present the workstation client cert pair, or set `client_auth = "none"`/`"optional"` in `docker/compose/otel.docker.toml` and restart |
| Export succeeds but SDK logs a partial-success warning | Individual records exceed `max_request_bytes` and were rejected | Raise `[server] max_request_bytes`, or reduce record/batch size |
| HTTP 503 / gRPC `UNAVAILABLE` on export | Collector could not publish to NATS (broker down or stream unavailable) | Retryable; check `kubectl logs deploy/serviceradar-log-collector -n <namespace>` and NATS health |
| Telemetry accepted but missing from queries | Wrong table/entity, or trace summaries not refreshed yet | Check the [storage model](#storage-model) and [rollup recovery runbook](./observability-rollup-recovery.md); run `scripts/otel-conformance.sh` to isolate the failing signal |

For ingestion volume and Timescale retention jobs, use the
[CNPG Monitoring dashboards](./cnpg-monitoring.md) or run ad-hoc SQL from the
`serviceradar-tools` pod (`cnpg-sql "SELECT COUNT(*) FROM otel_traces WHERE timestamp >
now() - INTERVAL '5 minutes';"`).
