## ADDED Requirements

### Requirement: Elixir OTEL Exporter Configuration
Elixir services (core-elx, web-ng, agent-gateway) in the Docker Compose stack SHALL include OTEL exporter environment variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_CERT_DIR`, `OTEL_CERT_NAME`, `OTEL_SERVICE_NAME`) and SHALL depend on the `otel` service to ensure the collector is available before telemetry export begins.

#### Scenario: Elixir service exports telemetry to OTEL collector
- **WHEN** the Docker Compose stack is started
- **THEN** each Elixir service connects to `serviceradar-otel:4317` via mTLS and exports traces, metrics, and logs

#### Scenario: OTEL collector unavailable at startup
- **WHEN** the OTEL collector is not yet ready when an Elixir service starts
- **THEN** the Elixir service starts normally and retries OTLP export with backoff until the collector becomes available
