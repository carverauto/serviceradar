# plugin-sdk-go Specification

## Purpose
Provide a Go SDK that enables ServiceRadar plugin authors to build Wasm checkers with minimal host-guest boilerplate while producing valid `serviceradar.plugin_result.v1` payloads.

## ADDED Requirements
### Requirement: TinyGo-compatible entrypoint
The SDK MUST provide a TinyGo-compatible execution entrypoint that captures plugin output and returns a serialized `serviceradar.plugin_result.v1` payload.

#### Scenario: Execute wrapper returns a result payload
- **GIVEN** a plugin uses the SDK execution wrapper with a result builder
- **WHEN** the agent invokes the plugin entrypoint
- **THEN** the wrapper returns a serialized `serviceradar.plugin_result.v1` payload

### Requirement: Configuration decoding
The SDK MUST load the plugin configuration JSON provided by the host and decode it into a caller-supplied Go struct.

#### Scenario: Configuration JSON decodes successfully
- **GIVEN** the host provides valid JSON configuration
- **WHEN** the plugin calls `GetConfig(&cfg)`
- **THEN** the SDK populates `cfg` with the decoded values

#### Scenario: Configuration JSON is invalid
- **GIVEN** the host provides invalid JSON configuration
- **WHEN** the plugin calls `GetConfig(&cfg)`
- **THEN** the SDK returns a decoding error

### Requirement: Result builder with schema compliance
The SDK MUST provide a result builder that emits JSON compliant with `serviceradar.plugin_result.v1`, including status, summary, details, widgets, and metrics.

#### Scenario: Builder emits schema-compliant result
- **GIVEN** a plugin sets status, summary, and adds a stat card and metric
- **WHEN** the plugin returns the result via the SDK
- **THEN** the serialized JSON includes those fields per `serviceradar.plugin_result.v1`

### Requirement: Event emission and alert promotion hints
The SDK MUST allow plugins to emit events and request immediate alert promotion by setting `alert_hint` and `condition_id` on the result payload.

#### Scenario: Plugin requests immediate alert
- **GIVEN** a plugin emits an event and calls `RequestImmediateAlert("latency_spike")`
- **WHEN** the result is serialized
- **THEN** the payload includes the emitted event
- **AND** `alert_hint` is `true`
- **AND** `condition_id` is `latency_spike`

### Requirement: Threshold helpers
The SDK MUST provide helper methods for comparing metric values against thresholds and setting the result status accordingly.

#### Scenario: Threshold helper updates status
- **GIVEN** a plugin defines warning and critical thresholds for a metric
- **WHEN** the metric exceeds the critical threshold
- **THEN** the helper sets the result status to `CRITICAL`

### Requirement: Host function wrappers
The SDK MUST expose Go-friendly wrappers for host functions, including HTTP requests and stream-oriented connections, without direct syscalls.

#### Scenario: HTTP wrapper performs a request
- **GIVEN** a plugin calls `sdk.HTTP.Get("https://example.com/health")`
- **WHEN** the host function executes
- **THEN** the SDK returns the response status, body, and timing data

#### Scenario: Stream wrapper provides I/O
- **GIVEN** a plugin opens a TCP stream through the SDK
- **WHEN** it writes and reads data
- **THEN** the SDK forwards I/O through host functions and returns the response

### Requirement: Logging bridge
The SDK MUST expose logging methods that forward messages to the agent logger with severity mapping.

#### Scenario: Log message forwarded
- **GIVEN** a plugin calls `sdk.Log.Warn("threshold exceeded")`
- **WHEN** the SDK forwards the log to the host
- **THEN** the log is recorded with warning severity

### Requirement: Memory helpers
The SDK MUST export `alloc` and `dealloc` functions for host-to-guest memory management.

#### Scenario: Host writes into plugin memory
- **GIVEN** the host needs to pass a payload to the plugin
- **WHEN** it calls `alloc` to reserve memory and later `dealloc`
- **THEN** the SDK allocates and frees the requested memory range
