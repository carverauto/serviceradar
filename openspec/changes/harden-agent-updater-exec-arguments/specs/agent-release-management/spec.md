## ADDED Requirements

### Requirement: Managed release updater arguments are validated before exec
Before a package-managed agent spawns the updater for managed release activation, it SHALL validate every updater-bound activation argument derived from network command metadata. The staged release version SHALL match the managed release version token format, the command identifier SHALL be a UUID, the command type SHALL be an allowed managed release activation command type, and none of those values SHALL contain control characters or NUL bytes. If any validation fails, the agent SHALL reject activation and report a validation error instead of executing the updater.

#### Scenario: Managed release activation rejects malformed command metadata
- **GIVEN** a staged managed release is ready for activation
- **AND** the received release command has a malformed `command_id`, an unexpected `command_type`, or control characters in updater-bound metadata
- **WHEN** the agent prepares updater activation
- **THEN** the agent SHALL reject the activation attempt before spawning the updater
- **AND** the rollout target SHALL surface an activation validation error

#### Scenario: Managed release activation rejects non-canonical version tokens
- **GIVEN** a staged managed release is ready for activation
- **AND** the release `version` contains characters outside the managed release token format
- **WHEN** the agent prepares updater activation
- **THEN** the agent SHALL reject the activation attempt before spawning the updater
- **AND** the updater SHALL NOT receive the invalid version string

#### Scenario: Managed release activation accepts canonical updater arguments
- **GIVEN** a staged managed release is ready for activation
- **AND** the release `version` uses the managed release token format
- **AND** the release `command_id` is a UUID
- **AND** the release `command_type` is `agent.update_release`
- **WHEN** the agent prepares updater activation
- **THEN** the agent SHALL invoke the updater with those canonicalized values
