## ADDED Requirements

### Requirement: Unified log collector daemon
The system SHALL provide a single daemon (`serviceradar-log-collector`) that accepts log data from multiple input protocols and publishes to NATS JetStream. The daemon composes `serviceradar-flowgger` and `serviceradar-otel` as library dependencies under a thin orchestration layer.

#### Scenario: Syslog UDP input to NATS
- **WHEN** a syslog message is received on the UDP input (Flowgger pipeline)
- **THEN** the collector SHALL decode it (RFC 3164 or RFC 5424) and publish to the `logs.syslog` NATS subject

#### Scenario: Syslog TCP/TLS input to NATS
- **WHEN** a syslog message is received on the TCP or TLS input (Flowgger pipeline)
- **THEN** the collector SHALL decode it and publish to the `logs.syslog` NATS subject

#### Scenario: GELF input to NATS
- **WHEN** a GELF message is received on the configured input (Flowgger pipeline)
- **THEN** the collector SHALL decode it and publish to the `logs.syslog` NATS subject

#### Scenario: OTEL gRPC log input to NATS
- **WHEN** an OpenTelemetry ExportLogsServiceRequest is received on the gRPC input (OTEL pipeline)
- **THEN** the collector SHALL publish to the `logs.otel` NATS subject

#### Scenario: OTEL gRPC traces and metrics to NATS
- **WHEN** OpenTelemetry trace or metric export requests are received on the gRPC input (OTEL pipeline)
- **THEN** the collector SHALL publish to `otel.traces` or `otel.metrics` NATS subjects respectively

### Requirement: Per-pipeline enable/disable
The system SHALL allow each pipeline (Flowgger, OTEL) to be independently enabled or disabled via the unified config without recompilation.

#### Scenario: Disabled pipeline does not start
- **GIVEN** the OTEL pipeline is set to `enabled = false` in the unified config
- **WHEN** the collector starts
- **THEN** the collector SHALL NOT start the OTEL gRPC server
- **AND** the collector SHALL log that the OTEL pipeline is disabled

### Requirement: Config delegation
The unified config SHALL delegate to native config files for each sub-collector rather than rewriting their config formats.

#### Scenario: Config delegation to native files
- **GIVEN** the unified config contains `[flowgger] config_file = "/etc/serviceradar/flowgger.toml"`
- **WHEN** the collector starts the Flowgger pipeline
- **THEN** the collector SHALL pass the native config file path to Flowgger's `start()` function
- **AND** existing Flowgger configs SHALL work without modification (except removal of `[grpc]` section)

### Requirement: Unified gRPC health check
The collector SHALL expose a single gRPC health check endpoint (tonic-health on port 50044) reporting status for all enabled pipelines.

#### Scenario: Health check reports all pipelines
- **WHEN** a gRPC health check request is received
- **THEN** the response SHALL report `SERVING` for services: `""`, `"log-collector"`, and each enabled pipeline (`"flowgger"`, `"otel"`)

#### Scenario: Health check replaces per-daemon endpoints
- **WHEN** the unified collector is deployed
- **THEN** Kubernetes probes SHALL use `grpc:50044` instead of the previous per-daemon probe targets
- **AND** Flowgger's built-in gRPC health server SHALL be disabled (by omitting `[grpc]` from delegated config)

### Requirement: Compile-time feature flags
The collector crate SHALL support Cargo feature flags (`syslog`, `otel`) so that unused pipelines can be excluded from the binary at build time. Both features are enabled by default.

#### Scenario: Build without syslog
- **GIVEN** the crate is compiled with `--no-default-features --features otel`
- **WHEN** the binary starts with a config enabling only the OTEL pipeline
- **THEN** the binary SHALL function correctly without Flowgger code included

### Requirement: Backward-compatible NATS subjects
The collector SHALL publish to the same NATS subjects as the previous separate daemons (`logs.syslog`, `logs.otel`, `otel.traces`, `otel.metrics`) on the same `events` JetStream stream.

#### Scenario: Existing consumers unaffected
- **GIVEN** downstream consumers are subscribed to `logs.syslog` and `logs.otel`
- **WHEN** the unified collector replaces the separate daemons
- **THEN** consumers SHALL continue to receive messages on the same subjects with the same encoding

## DEFERRED Requirements

### Requirement: Unified NATS output (deferred)
Unifying the NATS output implementations from Flowgger (sync worker threads) and OTEL (async `async_nats`) is deferred to preserve Flowgger's upstream compatibility.

### Requirement: Unified Prometheus metrics (deferred)
A single Prometheus `/metrics` endpoint covering all pipelines is deferred to a future iteration. Each pipeline retains its own metrics for now.
