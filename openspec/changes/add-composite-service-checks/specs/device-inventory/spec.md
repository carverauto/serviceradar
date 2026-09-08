## ADDED Requirements

### Requirement: External Device Fact Write API

The system SHALL provide an authenticated endpoint that lets an external
validation tool set bounded scalar facts on a device's metadata without needing
access to any other device field.

The endpoint SHALL write each fact's plain value at its metadata key, so that
existing metadata consumers observe it unchanged, and SHALL additionally record
server-stamped provenance for that key comprising the writing principal and the
write time.

Provenance SHALL be server-stamped. The endpoint SHALL NOT accept a
caller-supplied write time.

#### Scenario: External tool writes a boolean fact

- **GIVEN** a principal holding the device fact write permission
- **WHEN** it sends `{"facts": {"nac_applied": true}}` for a known device
- **THEN** the device's metadata SHALL contain `nac_applied = true`
- **AND** provenance for `nac_applied` SHALL record the principal and the server
  write time

#### Scenario: Provenance enables freshness evaluation

- **GIVEN** a fact written two hours ago
- **WHEN** a consumer requiring a 24 hour maximum age reads it
- **THEN** the recorded provenance SHALL allow the value to be judged fresh
- **AND** the same value read 25 hours after the write SHALL be judged stale

#### Scenario: Caller cannot back-date a fact

- **WHEN** a caller includes a write timestamp in the request
- **THEN** the supplied timestamp SHALL be ignored
- **AND** the server write time SHALL be recorded

#### Scenario: Unknown device is rejected

- **WHEN** a fact write targets a device UID that does not exist
- **THEN** the request SHALL be rejected with a not-found response
- **AND** no device SHALL be created

#### Scenario: Unauthorized principal is rejected

- **GIVEN** a principal lacking the device fact write permission
- **WHEN** it attempts a fact write
- **THEN** the request SHALL be rejected
- **AND** device metadata SHALL be unchanged

### Requirement: Device Fact Write Bounds

The system SHALL bound what an external device fact write can place in device
metadata.

Fact keys SHALL match a restricted lowercase identifier pattern. Fact values
SHALL be scalars. The number of externally written facts per device SHALL be
capped. Keys that are managed by internal enrichment, including passive
fingerprint evidence, SHALL be reserved and SHALL NOT be writable through this
endpoint.

#### Scenario: Invalid key is rejected

- **WHEN** a fact write uses a key that does not match the permitted pattern
- **THEN** the request SHALL be rejected with a validation error naming the key
- **AND** no fact in the request SHALL be applied

#### Scenario: Non-scalar value is rejected

- **WHEN** a fact write supplies an object or array as a value
- **THEN** the request SHALL be rejected with a validation error

#### Scenario: Reserved key is rejected

- **WHEN** a fact write targets a key reserved for internal enrichment
- **THEN** the request SHALL be rejected
- **AND** the existing internal value SHALL be unchanged

#### Scenario: Fact cap is enforced

- **GIVEN** a device already carrying the maximum number of externally written
  facts
- **WHEN** a write introduces an additional new key
- **THEN** the request SHALL be rejected with a validation error stating the cap
