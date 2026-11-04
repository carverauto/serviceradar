## MODIFIED Requirements

### Requirement: Zen stream initialization succeeds
Zen SHALL publish to the block subjects of the signal-separated telemetry streams, which EventWriter owns and creates, and SHALL seed initial rules without creating or updating any stream's subjects and without JetStream subject overlap errors.

#### Scenario: Zen startup
- **WHEN** the zen service starts with the compose config
- **THEN** it SHALL NOT add subjects to any stream
- **AND** initial rule seeding SHALL complete without JetStream or auth failures
