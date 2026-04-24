# Change: Add OpenTelemetry instrumentation to Elixir applications

## Why

The OTEL collector (`serviceradar-otel:4317`) is already running in both Docker Compose and Kubernetes stacks, and Go services are fully instrumented with traces, metrics, and logs. However, the Elixir apps (`web-ng`, `agent-gateway`, `core-elx`) emit zero telemetry to the collector. This creates a blind spot across the control plane, gateway orchestration, and web UI layers. Bridging the existing Erlang `telemetry` events to OpenTelemetry and exporting via OTLP/gRPC will close this gap.

## What Changes

- Add `opentelemetry`, `opentelemetry_api`, `opentelemetry_exporter`, and ecosystem instrumentation packages (`opentelemetry_phoenix`, `opentelemetry_ecto`, `opentelemetry_oban`, `opentelemetry_grpc`) to the shared dependency tree
- Create a shared OTEL bootstrap module (`ServiceRadar.Telemetry.OtelSetup`) in `serviceradar_core` that configures the SDK, OTLP exporter (gRPC, mTLS), and resource attributes (service name, version, environment)
- Wire Phoenix (web-ng), Ecto/AshPostgres, Oban, and gRPC (agent-gateway) auto-instrumentation
- Bridge existing custom telemetry events (device actors, cluster health) to OTEL spans/metrics
- Export logs via OTLP using `opentelemetry_logger_handler`
- Configure all Elixir services in Docker Compose and Helm to send to `serviceradar-otel:4317` with mTLS
- Update `values-demo.yaml` and `docker-compose.yml` with OTEL environment variables for Elixir services

## Impact

- Affected specs: `ash-observability`, `docker-compose-stack`
- Affected code:
  - `elixir/serviceradar_core/` (shared OTEL library, telemetry bridge)
  - `elixir/web-ng/serviceradar/` (Phoenix + Ecto instrumentation)
  - `elixir/serviceradar_agent_gateway/` (gRPC instrumentation)
  - `elixir/serviceradar_core_elx/` (release config, runtime OTEL setup)
  - `docker-compose.yml` (env vars for Elixir services)
  - `helm/serviceradar/` (values, templates for OTEL config)
- No breaking changes
