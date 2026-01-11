# Event Writer Capability

## ADDED Requirements

### Requirement: EventWriter GenServer processes NATS JetStream messages

The core-elx application SHALL include an EventWriter GenServer that consumes messages from NATS JetStream streams and writes them to CNPG hypertables.

#### Scenario: EventWriter consumes telemetry messages

**Given** the EventWriter is enabled via `EVENT_WRITER_ENABLED=true`
**And** NATS JetStream is available at the configured URL
**When** a telemetry message is published to the `telemetry.>` subject
**Then** the EventWriter SHALL consume the message within 5 seconds
**And** insert the telemetry data into the `timeseries_metrics` hypertable
**And** acknowledge the message to NATS JetStream

#### Scenario: EventWriter handles batch inserts

**Given** the EventWriter is processing messages
**When** multiple messages arrive within the batch timeout (default 1000ms)
**Then** the EventWriter SHALL batch messages together
**And** insert them in a single database transaction
**And** acknowledge all messages in the batch on success

#### Scenario: EventWriter handles NATS disconnection

**Given** the EventWriter is connected to NATS
**When** the NATS connection is lost
**Then** the EventWriter SHALL attempt to reconnect with exponential backoff
**And** resume message processing when reconnected
**And** not lose any unacknowledged messages

### Requirement: EventWriter supports multiple stream processors

The EventWriter SHALL support processing messages from multiple NATS JetStream streams, each with a dedicated processor for the message format.

#### Scenario: EventWriter requires tenant context for processing

**Given** the EventWriter is running with multi-tenant support
**When** a message is received without tenant context from the process/Ash scope
**Then** the EventWriter SHALL reject the message
**And** it SHALL NOT write any database records for that message

#### Scenario: EventWriter processes syslog events

**Given** the EventWriter is configured with the events stream
**When** a syslog message (CloudEvents or GELF) is published to `events.>`
**Then** the EventWriter SHALL parse the syslog payload
**And** insert the event into the `ocsf_events` hypertable as Event Log Activity (class_uid: 1008)

#### Scenario: EventWriter processes SNMP trap events

**Given** the EventWriter is configured with the snmp traps stream
**When** an SNMP trap message is published to `logs.snmp`
**Then** the EventWriter SHALL parse the trap payload
**And** insert the event into the `ocsf_events` hypertable as Event Log Activity (class_uid: 1008)

#### Scenario: EventWriter processes sweep stream

**Given** the EventWriter is configured with the sweep stream
**When** a sweep result message is published to `sweep.>`
**Then** the EventWriter SHALL parse the sweep result
**And** insert the data into the `sweep_host_states` hypertable

#### Scenario: EventWriter processes netflow stream

**Given** the EventWriter is configured with the netflow stream
**When** a netflow message is published to `netflow.>`
**Then** the EventWriter SHALL parse the netflow data
**And** insert the metrics into the `netflow_metrics` hypertable

#### Scenario: EventWriter processes OTEL streams

**Given** the EventWriter is configured with OTEL streams
**When** an OTEL metrics message is published to `otel.metrics.>`
**Then** the EventWriter SHALL insert data into the `otel_metrics` hypertable
**When** an OTEL trace message is published to `otel.traces.>`
**Then** the EventWriter SHALL insert data into the `otel_traces` hypertable

#### Scenario: EventWriter processes logs stream

**Given** the EventWriter is configured with the logs stream
**When** a log message is published to `logs.>`
**Then** the EventWriter SHALL parse the structured log
**And** insert the data into the `logs` hypertable

### Requirement: EventWriter is conditionally enabled

The EventWriter SHALL only start when explicitly enabled, to allow gradual migration from the Go db-event-writer.

#### Scenario: EventWriter disabled by default

**Given** `EVENT_WRITER_ENABLED` is not set or is `false`
**When** core-elx starts
**Then** the EventWriter Supervisor SHALL NOT be started
**And** no NATS JetStream connections SHALL be established

#### Scenario: EventWriter enabled via environment

**Given** `EVENT_WRITER_ENABLED=true`
**When** core-elx starts
**Then** the EventWriter Supervisor SHALL be started
**And** the Broadway pipeline SHALL connect to NATS JetStream

### Requirement: EventWriter emits telemetry metrics

The EventWriter SHALL emit telemetry events for monitoring and observability.

#### Scenario: EventWriter emits batch processing metrics

**Given** the EventWriter processes a batch of messages
**Then** it SHALL emit a telemetry event `[:serviceradar, :event_writer, :batch_processed]`
**With** measurements including `count` and `duration`
**And** metadata including `stream` and `processor`

#### Scenario: EventWriter emits error metrics

**Given** a message fails to process
**Then** the EventWriter SHALL emit a telemetry event `[:serviceradar, :event_writer, :message_failed]`
**With** measurements including `count`
**And** metadata including `stream` and `reason`

### Requirement: EventWriter uses mTLS for NATS connection

The EventWriter SHALL use mTLS certificates for secure NATS JetStream connections, consistent with other ServiceRadar components.

#### Scenario: EventWriter configures mTLS from cert directory

**Given** `DATASVC_CERT_DIR=/etc/serviceradar/certs`
**And** certificate files exist at `core.pem` and `core-key.pem`
**When** the EventWriter connects to NATS
**Then** it SHALL use the certificates for mTLS authentication

## MODIFIED Requirements

### Requirement: Core-elx application supervisor includes EventWriter

The core-elx Application supervisor SHALL conditionally include the EventWriter supervisor.

#### Scenario: EventWriter added to supervision tree

**Given** `EVENT_WRITER_ENABLED=true`
**When** core-elx Application starts
**Then** `ServiceRadar.EventWriter.Supervisor` SHALL be in the supervision tree
**And** it SHALL be supervised with `:one_for_one` strategy
