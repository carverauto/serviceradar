## MODIFIED Requirements

### Requirement: Access Credentials MUST Record Usage Reliably
API tokens and OAuth clients SHALL record usage in a way that preserves accurate counters under concurrent requests.

#### Scenario: Concurrent use of the same API token
- **WHEN** multiple requests record usage for the same API token at the same time
- **THEN** each successful use MUST increment `use_count`
- **AND** the final counter MUST reflect all successful uses rather than losing increments

#### Scenario: Concurrent use of the same OAuth client
- **WHEN** multiple requests record usage for the same OAuth client at the same time
- **THEN** each successful use MUST increment `use_count`
- **AND** the final counter MUST reflect all successful uses rather than losing increments

### Requirement: First User Bootstrap MUST Be Deterministic
The system SHALL assign the initial admin role in a way that does not grant admin to multiple concurrent first registrants.

#### Scenario: Two users register concurrently on an empty deployment
- **WHEN** two registration requests race during initial bootstrap
- **THEN** at most one newly created user SHALL be promoted to `admin`
- **AND** the other user SHALL retain the non-admin default role
