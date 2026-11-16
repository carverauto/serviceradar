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
- **WHEN** a rule whose graph connects its input directly to its output sets a top-level field to null
- **THEN** that field is absent from the normalized record
- **AND** a field that reached the rule as null is kept

### Requirement: Versioned ruleset activation
The collector SHALL receive effective rules through datasvc, validate complete snapshots before activation, and bind each batch to one version without per-record control-plane requests.

#### Scenario: An update fails compilation
- **WHEN** a candidate snapshot fails compilation
- **THEN** the previous validated snapshot remains active
- **AND** stale/error status is exposed

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

#### Scenario: Persistence partially fails
- **WHEN** persistence has not succeeded for the complete batch
- **THEN** the batch is not acknowledged as persisted
- **AND** retry retains stable record identities
