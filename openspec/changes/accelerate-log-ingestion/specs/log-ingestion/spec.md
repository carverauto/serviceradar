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
The collector SHALL receive effective rules from the rule store, validate complete snapshots before activation, and bind each batch to one version without per-record control-plane requests. The store and transport are defined by `collector-rule-distribution`.

#### Scenario: An update fails compilation
- **WHEN** a candidate snapshot fails compilation
- **THEN** the previous validated snapshot remains active
- **AND** stale/error status is exposed

#### Scenario: A collector starts while the rule store is unreachable
- **WHEN** the collector has no validated snapshot
- **THEN** it accepts syslog and publishes it as `collector-rule-distribution` requires for a collector without a ruleset
- **AND** it publishes normalized batches from the first record after a snapshot is active

#### Scenario: A watch reconnects
- **WHEN** the watch disconnects
- **THEN** the collector reconciles through an authoritative fetch
- **AND** it does not assume the current Watch API provides revision replay

### Requirement: Binary semantic parity
The binary path SHALL preserve log fields, normalization, redaction, provenance and stable record identity, and SHALL bound batch bytes, records and age. A batch on `logs.normalized.<kind>` SHALL carry the schema header, and SHALL carry `Sr-Ruleset-Id` with the validated snapshot digest when rules were applied; a batch without `Sr-Ruleset-Id` is built-in-mapping pass-through as `collector-rule-distribution` defines.

#### Scenario: Equivalent legacy and binary input
- **WHEN** both paths process the same synthetic input with the same rules
- **THEN** persisted fields and required downstream effects agree

#### Scenario: A batch carries no ruleset digest
- **WHEN** a batch with the schema header and no `Sr-Ruleset-Id` arrives on `logs.normalized.<kind>`
- **THEN** EventWriter stores it with the built-in mapping, without running Zen and without rejecting it
- **AND** it records that no ruleset was applied

### Requirement: Trusted normalization and durable acknowledgment
EventWriter SHALL skip Zen only for authorized collector output on `logs.normalized.`, whether the batch carries a ruleset digest or, as built-in-mapping pass-through, none, use the selected StarRocks or CNPG backend, and acknowledge a batch only after successful persistence under its replay contract.

#### Scenario: An untrusted body claims normalization
- **WHEN** log content supplies a normalized flag
- **THEN** that flag cannot bypass normalization or redaction

#### Scenario: A sender switches format on a rule-bearing subject
- **WHEN** a protobuf log batch arrives on a `logs.` subject other than `logs.otel` or `logs.normalized.`
- **THEN** it is refused and counted as rejected

#### Scenario: Another identity publishes the normalized subject
- **WHEN** any NATS identity other than a collector identity or the edge leaf that forwards an edge collector's batches publishes to `logs.normalized.`
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
