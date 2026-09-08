## ADDED Requirements

### Requirement: Integration Sync Status Visibility
The web-ng Integrations UI SHALL display sync execution status and diagnostics for each integration source.

#### Scenario: Enabled source with no runs shows diagnostics
- **GIVEN** an enabled integration source with no `last_sync_at`
- **WHEN** an operator views the Integrations list
- **THEN** the status indicates the source has never run
- **AND** the row surfaces the assigned agent state (connected/disconnected)

#### Scenario: Failed sync shows last error
- **GIVEN** an integration source with `last_sync_result = failed` and a `last_error_message`
- **WHEN** an operator views the integration details
- **THEN** the error message is displayed with a failure status indicator
