## Context

ServiceRadar's OTEL collector is a Rust-based service already deployed in both Docker Compose and Kubernetes. It accepts OTLP/gRPC on port 4317 (mTLS required) and publishes events to NATS JetStream. Go services use the official `go.opentelemetry.io/otel` SDK with OTLP gRPC exporters. The Elixir side has Erlang `telemetry` events but no OTEL bridge or exporter.

The Erlang/Elixir OTEL ecosystem (`opentelemetry-erlang`) provides a mature SDK with auto-instrumentation libraries for Phoenix, Ecto, and Oban that hook into the existing telemetry events.

Stakeholders: platform team (observability), Elixir service owners.

## Goals / Non-Goals

### Goals
- Traces: auto-instrument Phoenix requests, Ecto queries, Oban jobs, and gRPC calls; propagate trace context end-to-end
- Metrics: export Erlang VM metrics (memory, schedulers, GC), Ecto pool stats, Oban queue depth/duration, and custom device-actor counters via OTLP
- Logs: route Elixir Logger output through OTLP so structured logs appear alongside traces in the collector
- mTLS: all OTLP exports use the same cert infrastructure (SPIFFE in k8s, non-SPIFFE certs in Docker Compose)
- Shared library: one module in `serviceradar_core` configures the SDK so all downstream apps inherit consistent resource attributes and exporter settings

### Non-Goals
- Custom OTEL collector changes (the Rust collector is out of scope)
- Replacing existing Erlang `telemetry` events (they continue to work; OTEL bridges on top)
- Dashboards or alerting rules (downstream concern)
- Instrumenting Rust NIFs (SRQL) — future work

## Decisions

### Decision 1: Shared OTEL setup in serviceradar_core
**What:** A `ServiceRadar.Telemetry.OtelSetup` module that calls `opentelemetry:setup/1` and configures the OTLP exporter.
**Why:** All three apps (core-elx, web-ng, agent-gateway) depend on serviceradar_core, so this avoids duplication. Each app passes its own `service.name` at boot.
**Alternatives:** Per-app configuration — rejected because it leads to drift and duplicated mTLS plumbing.

### Decision 2: Use opentelemetry_erlang ecosystem packages
**What:** `opentelemetry`, `opentelemetry_api`, `opentelemetry_exporter` (OTLP/gRPC), plus auto-instrumentation: `opentelemetry_phoenix`, `opentelemetry_ecto`, `opentelemetry_oban`.
**Why:** These are the official CNCF packages, well-maintained, and hook into existing telemetry events with zero manual span creation for common paths.
**Alternatives:** Custom telemetry handlers exporting to Prometheus — rejected because the collector already speaks OTLP and we want traces, not just metrics.

### Decision 3: OTLP/gRPC exporter with mTLS
**What:** Export via gRPC to `serviceradar-otel:4317` using the same TLS certificates that other services use.
**Why:** Consistent with Go services; gRPC is more efficient than HTTP for high-volume telemetry; mTLS is mandatory in both environments.
**Alternatives:** OTLP/HTTP (port 4318) — viable but gRPC is the established pattern in ServiceRadar.

### Decision 4: Environment-variable-driven configuration
**What:** OTEL endpoint, TLS cert paths, service name, and sampling ratio are controlled via env vars (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, etc.) plus ServiceRadar-specific `OTEL_CERT_DIR`, `OTEL_CERT_NAME`.
**Why:** Matches Docker Compose / Helm injection patterns; no code changes needed to switch environments.

### Decision 5: Logger handler for OTLP log export
**What:** Use `opentelemetry_logger_handler` to capture Elixir Logger output and export as OTLP logs.
**Why:** Correlates logs with traces via trace context; the collector already routes to `logs.otel` NATS subject.

## Risks / Trade-offs

- **Performance overhead**: OTEL SDK adds per-request span allocation. Mitigated by configurable sampling ratio (default 1.0 in dev, tunable in prod).
- **Dependency surface**: Adding ~8 new Hex packages. Mitigated by using only official CNCF-maintained packages.
- **mTLS cert availability**: Elixir services must have access to TLS certs at runtime. In Docker Compose this is via shared volume; in k8s via SPIRE. Risk: cert rotation could cause brief export failures. Mitigated by the SDK's retry/backoff.
- **Erlang distribution + OTEL context**: In clustered deployments (Horde), trace context does not automatically propagate across Erlang distribution. Mitigated by injecting trace context into GenServer call metadata where cross-node tracing is needed (future enhancement).

## Migration Plan

1. Add OTEL deps to `serviceradar_core/mix.exs` — no runtime behavior change until setup is called
2. Implement `OtelSetup` module with unit tests
3. Wire up in core-elx release (Application start callback)
4. Wire up in web-ng (Phoenix telemetry attach)
5. Wire up in agent-gateway (gRPC instrumentation)
6. Add env vars to docker-compose.yml for all three services
7. Add env vars to Helm values/templates
8. Smoke test: verify traces/metrics/logs appear in collector output (NATS subjects)

Rollback: remove the Application.start OTEL setup call; services revert to no-export telemetry.

## Open Questions

- Should we instrument Horde process distribution with custom spans now, or defer to a follow-up?
- Desired default sampling ratio for production?
- Should web-ng LiveView channel events get custom spans (beyond HTTP request tracing)?
