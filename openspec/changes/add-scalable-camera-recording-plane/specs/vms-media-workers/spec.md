## ADDED Requirements

### Requirement: Worker pools cannot consume recording reservations
The system SHALL admit analysis, transcription and derived-video jobs into independent bounded CPU/GPU pools, carrying authorized media references through durable messaging rather than media payloads. Workers SHALL not consume recorder reservations or acquire independent camera sessions for an existing source/profile.

#### Scenario: Analysis falls behind ongoing recording
- **WHEN** detection or transcription exceeds its configured queue age, bytes, attempts or execution budget
- **THEN** the system SHALL reject, expire or skip optional work with an observable analysis outcome
- **AND** SHALL preserve capture, archival and live-view budgets
- **AND** SHALL not report missing analysis as missing footage or silently enable unbounded CPU fallback

#### Scenario: Worker is redelivered an expired reference
- **WHEN** a queued job resumes after its input capability expires or the source interval becomes unauthorized
- **THEN** execution SHALL obtain a newly authorized scoped capability or fail explicitly
- **AND** SHALL not use broad storage credentials or publish duplicate accepted results
- **AND** results and telemetry SHALL traverse the existing owned consumers rather than direct worker database writes
