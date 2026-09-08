## ADDED Requirements

### Requirement: Embedded Sync Runtime Executes Integration Sources
The agent SHALL execute enabled integration sources delivered via GetConfig, honoring per-source discovery and poll intervals, and SHALL publish discovered devices with `source` and `sync_service_id` metadata.

#### Scenario: Enabled Armis source executes on schedule
- **GIVEN** an IntegrationSource with `source_type = :armis` is enabled and assigned to `k8s-agent`
- **AND** the agent has received the source in its GetConfig payload
- **WHEN** the discovery interval elapses
- **THEN** the agent runs the Armis discovery cycle against the configured endpoint
- **AND** publishes device updates with `source = "armis"` and the matching `sync_service_id`

#### Scenario: Disabled source does not execute
- **GIVEN** an IntegrationSource is disabled
- **WHEN** the agent processes its GetConfig payload
- **THEN** no sync execution is scheduled for that source

### Requirement: Integration Source Lifecycle Status Updates
The core SHALL update IntegrationSource lifecycle fields based on sync execution outcomes, including `sync_status`, `last_sync_at`, `last_sync_result`, and `last_error_message`.

#### Scenario: Successful sync updates status
- **GIVEN** an enabled IntegrationSource is executed successfully
- **WHEN** sync results are ingested by core
- **THEN** `last_sync_at` is updated
- **AND** `last_sync_result` is set to `success` or `partial`
- **AND** `last_error_message` is cleared

#### Scenario: Failed sync records error
- **GIVEN** an enabled IntegrationSource fails during execution
- **WHEN** the failure is reported to core
- **THEN** `last_sync_result` is set to `failed` or `timeout`
- **AND** `last_error_message` records the failure reason
