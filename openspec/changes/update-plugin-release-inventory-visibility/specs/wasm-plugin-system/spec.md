## ADDED Requirements
### Requirement: First-party repository plugin catalog is paginated by selected release
The plugin administration UI SHALL keep the first-party repository release selector at the table header and SHALL paginate the selected release's plugin entries ten rows at a time. The UI SHALL NOT add per-row version selectors when a release-level selector already exists.

#### Scenario: Repository plugin catalog has more than ten entries
- **GIVEN** the selected first-party repository release contains twelve plugin entries
- **WHEN** an operator opens the First-party Repository Plugins table
- **THEN** the first page shows entries one through ten
- **AND** pagination controls allow navigating to entries eleven and twelve
- **AND** the release selector remains in the table header

### Requirement: Assigned Wasm plugins publish service visibility
Every assigned Wasm plugin that performs a scheduled or health-producing check SHALL publish a stable service status record that is visible in the `/services` list. The service identity SHALL include enough provenance to relate the row back to the agent, gateway, partition, plugin ID, package/version, and assignment.

#### Scenario: Assigned plugin reports healthy status
- **GIVEN** a UniFi, AlienVault, or other Wasm plugin package is assigned to an active agent
- **WHEN** the agent executes the plugin and receives a successful plugin result
- **THEN** the gateway/core ingestion path records a service status for that plugin assignment
- **AND** `/services` shows the plugin service with healthy status, agent, gateway, and plugin identity

#### Scenario: Assigned plugin reports failure or unknown status
- **GIVEN** a Wasm plugin package is assigned to an active agent
- **WHEN** the plugin execution fails, times out, traps, or reports unknown status
- **THEN** the gateway/core ingestion path records a failed or unknown service status for that plugin assignment
- **AND** `/services` shows the plugin service rather than omitting it

#### Scenario: Assigned plugin has no recent execution result
- **GIVEN** a Wasm plugin package is assigned to an active agent
- **AND** no recent plugin execution result has been ingested inside the freshness window
- **WHEN** an operator opens `/services`
- **THEN** the plugin service appears as stale or unknown
- **AND** the UI exposes enough context to distinguish missing execution data from an unassigned plugin

### Requirement: Plugin result statuses are normalized before ingestion
The Wasm plugin result path SHALL accept statuses emitted by the official SDKs and first-party sample plugins, including explicit failure states, and SHALL normalize them into the canonical service status model before ingestion. A plugin-reported failure SHALL be shown as a failed or unknown service state with error details, not rejected as an invalid plugin result solely because the status token is `failed`.

#### Scenario: Sample plugin reports failed status
- **GIVEN** a first-party sample plugin emits a plugin result with status `failed`
- **WHEN** the agent/gateway ingests the result
- **THEN** the status is normalized to the canonical failed service state
- **AND** `/services` shows the plugin check as failed with the plugin error details
- **AND** the result is not rejected with `plugin status invalid`
