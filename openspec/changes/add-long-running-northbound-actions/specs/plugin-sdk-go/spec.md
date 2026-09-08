## ADDED Requirements

### Requirement: Go SDK Deferred Action Helpers

The Go plugin SDK SHALL provide helpers for returning deferred northbound action results, decoding poll or webhook callback metadata, and returning final results from a poll.

#### Scenario: Plugin launches asynchronous vendor task
- **GIVEN** a Go Wasm plugin calls an external API that returns a vendor task ID
- **WHEN** the plugin uses the SDK deferred result helper
- **THEN** the SDK SHALL encode external correlation ID, next poll delay, and continuation state in the runtime-compatible result shape

#### Scenario: Plugin polls and fetches final results
- **GIVEN** a Go Wasm plugin receives a poll request for a previous deferred action
- **WHEN** the vendor API reports completion and exposes final results through a separate endpoint
- **THEN** the SDK SHALL allow the plugin to return the final result summary and per-target result payload

#### Scenario: Plugin registers a webhook-only vendor task
- **GIVEN** a Go Wasm plugin receives callback metadata on the selected target
- **WHEN** the vendor API can call ServiceRadar back when the task completes
- **THEN** the SDK SHALL expose `northbound_job_id` and callback metadata on the target snapshot
- **AND** the SDK SHALL allow the plugin to return `poll_mode: webhook` for deferred results
