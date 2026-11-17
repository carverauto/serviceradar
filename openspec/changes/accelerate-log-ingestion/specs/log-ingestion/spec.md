## ADDED Requirements

### Requirement: Bounded concurrent publication
The collector SHALL bound pending publications by message count and encoded bytes per publisher worker, preserve stable retry bytes and identity, and retain existing bounded ACK retry and certificate policy.

#### Scenario: An acknowledgment is delayed
- **WHEN** a publication waits for its ACK
- **THEN** other admitted publications can progress up to both bounds
- **AND** its retries retain the original admission slot

#### Scenario: A record cannot fit
- **WHEN** a record exceeds the configured byte budget
- **THEN** it produces an explicit failure outcome without deadlocking admission

### Requirement: Shared normalization semantics
Collector and NIF normalization SHALL share one Rust implementation preserving ordered evaluation, recursive overlays, explicit nulls and current error behavior without JSON text conversion between rules.

#### Scenario: A rule returns null
- **WHEN** a rule overlays an existing nested field with null
- **THEN** that field remains present with a null value

#### Scenario: A rule removes a top-level field
- **WHEN** a rule result names top-level fields in `serviceradar_remove_fields`
- **THEN** those fields are absent from the normalized record
- **AND** `serviceradar_remove_fields` is not written to the record

#### Scenario: A record names fields to remove
- **WHEN** an incoming record carries `serviceradar_remove_fields`
- **THEN** no rule receives that field
- **AND** no field is removed because of it

### Requirement: Versioned ruleset activation
The collector SHALL receive effective rules through datasvc, validate complete snapshots before activation, and bind each batch to one version without per-record control-plane requests.

#### Scenario: An update fails compilation
- **WHEN** a candidate snapshot fails compilation
- **THEN** the previous validated snapshot remains active
- **AND** stale/error status is exposed

#### Scenario: A collector starts while datasvc is unreachable
- **WHEN** the collector has no validated snapshot
- **THEN** it accepts syslog and publishes each record as JSON for EventWriter to normalize
- **AND** it publishes normalized batches from the first record after a snapshot is active

#### Scenario: A watch reconnects
- **WHEN** the watch disconnects
- **THEN** the collector reconciles through an authoritative fetch
- **AND** it does not assume the current Watch API provides revision replay

### Requirement: Binary semantic parity
The binary path SHALL preserve log fields, normalization, redaction, provenance and stable record identity, and SHALL bound batch bytes, records and age.

#### Scenario: Equivalent legacy and binary input
- **WHEN** both paths process the same synthetic input with the same rules
- **THEN** persisted fields and required downstream effects agree

### Requirement: Trusted normalization and durable acknowledgment
EventWriter SHALL skip repeated Zen only for authorized versioned collector output, use the selected StarRocks or CNPG backend, and acknowledge a batch only after successful persistence under its replay contract.

#### Scenario: An untrusted body claims normalization
- **WHEN** log content supplies a normalized flag
- **THEN** that flag cannot bypass normalization or redaction

#### Scenario: A sender switches format on a rule-bearing subject
- **WHEN** a protobuf log batch arrives on a `logs.` subject other than `logs.otel` or `logs.normalized.`
- **THEN** it is refused and counted as rejected

#### Scenario: Another identity publishes the normalized subject
- **WHEN** any NATS identity other than the log collector or an edge leaf publishes to `logs.normalized.`
- **THEN** the broker refuses the publish

#### Scenario: An edge leaf forwards normalized batches
- **WHEN** an edge leaf identity publishes to `logs.normalized.`
- **THEN** the broker accepts it, because that identity carries an edge collector's batches to the hub
- **AND** the edge site is trusted to state its own log columns

#### Scenario: A syslog sender's clock is wrong
- **WHEN** a zoned syslog time is more than 24 hours ahead of or 30 days behind the receive time, or an RFC 3164 time is more than an hour from it
- **THEN** the record is stored under the receive time on both paths
- **AND** its attributes keep the sender's time and mark the fallback

#### Scenario: Persistence partially fails
- **WHEN** persistence has not succeeded for the complete batch
- **THEN** the batch is not acknowledged as persisted
- **AND** retry retains stable record identities
