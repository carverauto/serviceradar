## ADDED Requirements

### Requirement: Deferred Wasm Action Results

The agent Wasm runtime SHALL allow a northbound action plugin to return a deferred result that records an external task ID, next poll timing or webhook-only mode, and opaque continuation state instead of a final action outcome.

#### Scenario: Plugin returns vendor task ID
- **GIVEN** an approved Wasm action invokes an external API that accepts work asynchronously
- **WHEN** the external API returns a task ID before the work is complete
- **THEN** the plugin SHALL return a deferred action result
- **AND** ServiceRadar SHALL persist the external correlation ID and continuation state
- **AND** the invocation target SHALL remain in a running or polling state

### Requirement: Wasm Action Callback Metadata

ServiceRadar SHALL provide per-target callback metadata to Wasm action plugins so webhook-capable external systems can report final results without polling.

#### Scenario: Plugin registers external webhook callback
- **GIVEN** an approved Wasm action invokes an external API that can call back on completion
- **WHEN** ServiceRadar dispatches the launch request
- **THEN** each target SHALL include a stable `northbound_job_id`
- **AND** each target SHALL include callback URL, path, token, and token header metadata
- **AND** the plugin SHALL be able to return a deferred webhook-only result without scheduling a poll

#### Scenario: External system posts callback result
- **GIVEN** a deferred target has callback metadata
- **WHEN** the external system posts a callback result with the correct job ID and token
- **THEN** ServiceRadar SHALL update only that target
- **AND** ServiceRadar SHALL recompute the parent invocation state from all targets

#### Scenario: External system posts invalid callback token
- **GIVEN** a deferred target has callback metadata
- **WHEN** a callback request has a missing or invalid token
- **THEN** ServiceRadar SHALL reject the request without updating target state

### Requirement: Wasm Action Poll Entrypoint

The agent Wasm runtime SHALL support a poll/resume entrypoint for deferred northbound action targets.

#### Scenario: Poll completes external task
- **GIVEN** a deferred action target has a due poll time
- **WHEN** ServiceRadar dispatches the poll request to the provider plugin
- **THEN** the plugin SHALL receive the original target context, validated inputs, and continuation state
- **AND** the plugin SHALL be able to return either another deferred poll response or a final action result

#### Scenario: Poll remains in progress
- **GIVEN** the external API reports that the task is still running
- **WHEN** the plugin handles the poll request
- **THEN** it SHALL return the next poll delay without marking the target completed
- **AND** ServiceRadar SHALL update progress metadata for Action History
