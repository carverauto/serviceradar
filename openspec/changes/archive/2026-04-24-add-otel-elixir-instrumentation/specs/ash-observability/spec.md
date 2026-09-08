## ADDED Requirements

### Requirement: OTLP Exporter Configuration
The system SHALL provide a shared OTEL setup module (`ServiceRadar.Telemetry.OtelSetup`) that configures the OpenTelemetry SDK with an OTLP/gRPC exporter targeting the ServiceRadar OTEL collector.

The module SHALL support mTLS certificate loading from environment variables (`OTEL_CERT_DIR`, `OTEL_CERT_NAME`) and SHALL set OpenTelemetry resource attributes including `service.name`, `service.version`, and `deployment.environment`.

#### Scenario: OTEL SDK initialization with mTLS
- **WHEN** an Elixir application calls `OtelSetup.configure/1` with a service name
- **THEN** the OpenTelemetry SDK is initialized with an OTLP/gRPC exporter pointed at the configured endpoint using mTLS credentials

#### Scenario: OTEL disabled when endpoint not configured
- **WHEN** the `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable is not set
- **THEN** the OTEL SDK is not initialized and the application runs without OTLP export

### Requirement: Phoenix Request Tracing
The system SHALL auto-instrument Phoenix HTTP requests using `opentelemetry_phoenix` so that each request produces an OTEL trace span with route, status code, and timing attributes.

#### Scenario: HTTP request generates trace span
- **WHEN** a user makes an HTTP request to web-ng
- **THEN** an OTEL trace span is created with the Phoenix route, HTTP method, response status code, and request duration

### Requirement: Ecto Query Tracing
The system SHALL auto-instrument Ecto database queries using `opentelemetry_ecto` so that each query produces an OTEL trace span with query source, operation, and timing attributes.

#### Scenario: Database query generates trace span
- **WHEN** an Ecto query is executed by any instrumented Elixir service
- **THEN** an OTEL trace span is created as a child of the current trace context with the query source table, operation type, and execution duration

### Requirement: Oban Job Tracing
The system SHALL auto-instrument Oban job execution using `opentelemetry_oban` so that each job produces an OTEL trace span with worker name, queue, and timing attributes.

#### Scenario: Oban job execution generates trace span
- **WHEN** an Oban job is executed in core-elx
- **THEN** an OTEL trace span is created with the worker module, queue name, job state, and execution duration

### Requirement: gRPC Call Tracing for Agent Gateway
The system SHALL instrument gRPC calls in the agent-gateway with OTEL trace context propagation so that traces span from agents through the gateway to the control plane.

#### Scenario: gRPC call propagates trace context
- **WHEN** an agent sends a gRPC request to the agent-gateway
- **THEN** the gateway creates or continues an OTEL trace span and propagates the trace context to downstream calls

### Requirement: OTLP Log Export
The system SHALL route Elixir Logger output through an OpenTelemetry logger handler so that structured logs are exported via OTLP and correlated with active trace spans.

#### Scenario: Log message exported with trace context
- **WHEN** a log message is emitted while a trace span is active
- **THEN** the log is exported via OTLP with the trace ID and span ID attached

### Requirement: Custom Telemetry Bridge
The system SHALL bridge existing custom telemetry events (device actor metrics, cluster health events) to OTEL metrics so they are exported alongside auto-instrumented data.

#### Scenario: Device actor telemetry exported as OTEL metric
- **WHEN** a `[:serviceradar, :actors, :device, :message_processed]` telemetry event fires
- **THEN** an OTEL counter metric is incremented with the device actor's tenant and device attributes
