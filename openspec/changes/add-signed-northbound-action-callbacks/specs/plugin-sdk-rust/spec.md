## MODIFIED Requirements
### Requirement: Northbound action helpers
The Rust plugin SDK SHALL provide helpers for returning deferred northbound action results, decoding poll or webhook callback metadata, and returning final results from a poll.

The SDK SHALL expose token-only callback metadata for compatibility and SHALL expose optional HMAC callback metadata when provided by ServiceRadar. SDK helpers SHALL make it straightforward for plugin authors to register callback URL, token header, timestamp header, signature header, and signing algorithm with external systems that support signed webhooks.

#### Scenario: Plugin returns deferred result
- **GIVEN** a Rust Wasm plugin launches an external task and receives an external task ID
- **WHEN** it returns a deferred result through the SDK
- **THEN** the SDK SHALL encode external correlation ID, webhook mode, and continuation state in the runtime-compatible result shape

#### Scenario: Plugin registers a token-only webhook vendor task
- **GIVEN** a Rust Wasm plugin receives callback metadata on the selected target
- **WHEN** the vendor API can call ServiceRadar back when the task completes but cannot sign webhook bodies
- **THEN** the SDK SHALL expose `northbound_job_id` and token-only callback metadata on the target snapshot
- **AND** the SDK SHALL allow the plugin to return `poll_mode: webhook` for deferred results

#### Scenario: Plugin registers a signed webhook vendor task
- **GIVEN** a Rust Wasm plugin receives HMAC callback metadata on the selected target
- **WHEN** the vendor API can sign webhook bodies
- **THEN** the SDK SHALL expose signing algorithm, timestamp header, signature header, and HMAC mode fields on the target snapshot
- **AND** the SDK SHALL provide helper behavior or examples for constructing the expected HMAC-SHA256 callback signature
- **AND** the SDK SHALL allow the plugin to return `poll_mode: webhook` for deferred results
