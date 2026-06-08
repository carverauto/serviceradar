## ADDED Requirements

### Requirement: Native add-ons emit telemetry batches
Native add-ons SHALL be able to emit source-agnostic telemetry batches to the local agent over the existing go-plugin add-on transport while remaining supervised by the native add-on framework. The telemetry contract SHALL support bounded batches, source identity, payload kind, stable event identity/idempotency key, observed and event timestamps, encoded payload bytes, and producer counters, without requiring the agent to understand the producer-specific wire format. Telemetry emission SHALL be opt-in via a capability identifier advertised in the add-on's `Info` response, so the agent only drains telemetry from add-ons that advertise it.

This requirement depends on the `agent-feature-sets` capability introduced by the `add-agent-feature-sets` change; this change MUST archive after it.

#### Scenario: Agent drains telemetry from a capability-advertising add-on
- **GIVEN** a supervised native add-on that advertises the native telemetry capability in its `Info` response
- **WHEN** the add-on receives local producer records and emits telemetry batches
- **THEN** the agent SHALL accept bounded batches from the add-on
- **AND** the agent SHALL preserve source kind, source instance, event identity, timestamps, payload kind, and payload bytes for upstream routing

#### Scenario: Legacy native add-on remains compatible
- **GIVEN** a native add-on that implements only Info, Configure, and Health and does not advertise the telemetry capability
- **WHEN** the agent launches the add-on after telemetry support is added
- **THEN** the add-on SHALL continue to run without implementing telemetry emission
- **AND** the agent SHALL NOT open the telemetry stream for that add-on and SHALL report no telemetry capability for it

### Requirement: Native log source add-ons are volume bounded
Native log source add-ons SHALL expose configurable queue limits, batch limits, and drop counters so high-volume local producers cannot create unbounded memory growth or silently overload the agent path. Drop counters SHALL be reported both as cumulative totals and as a per-batch delta so loss is observable upstream.

#### Scenario: Add-on queue reaches capacity
- **GIVEN** a native log source add-on receiving records faster than the agent can forward them
- **WHEN** the add-on queue reaches its configured capacity
- **THEN** the add-on SHALL apply the configured drop or backpressure policy
- **AND** Health and the emitted batch counters SHALL report dropped record counts and queue pressure

### Requirement: PowerDNS protobuf log source add-on
The platform SHALL provide a Rust native add-on that accepts PowerDNS protobuf DNS log messages from a localhost TCP listener, decodes DNS query/response and RPZ policy fields, and emits normalized telemetry through the generic native add-on telemetry contract. The listener SHALL parse the PowerDNS protobuf framing (a 2-byte big-endian length prefix per message) and SHALL bound message size.

#### Scenario: PowerDNS RPZ hit becomes add-on telemetry
- **GIVEN** PowerDNS Recursor is configured to send protobuf logging to the local add-on listener
- **AND** an RPZ policy hit occurs
- **WHEN** the add-on decodes the PowerDNS protobuf message
- **THEN** it SHALL emit a telemetry record containing the queried name, query type, response code, client endpoint, DNS server identity, RPZ policy name, policy match dimension, policy trigger, policy hit, and policy action
- **AND** the record SHALL be encoded as an OCSF DNS Activity (class_uid 4003) security event payload

#### Scenario: Full DNS logging is disabled by default
- **GIVEN** the PowerDNS log source add-on is running with default configuration
- **WHEN** PowerDNS sends non-policy DNS query or response messages
- **THEN** the add-on SHALL NOT emit those records by default
- **AND** full query or response logging SHALL require explicit configuration
