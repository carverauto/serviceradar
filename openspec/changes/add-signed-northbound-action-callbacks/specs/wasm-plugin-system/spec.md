## MODIFIED Requirements
### Requirement: Wasm Action Callback Metadata
ServiceRadar SHALL provide per-target callback metadata to Wasm action plugins so webhook-capable external systems can report final results without polling.

Callback metadata SHALL include the stable northbound job ID, callback path, callback URL when configured, bearer token, and token header. ServiceRadar SHALL also support optional HMAC-SHA256 callback signing metadata for integrations that can sign webhook payloads. Token-only callbacks SHALL remain valid for integrations that do not opt into HMAC. When a target is configured to require HMAC, ServiceRadar SHALL reject callback requests that do not include a valid timestamped signature over the raw request body.

#### Scenario: Plugin registers token-only external webhook callback
- **GIVEN** an approved Wasm action invokes an external API that can call back on completion but cannot sign webhook bodies
- **WHEN** ServiceRadar dispatches the launch request
- **THEN** each target SHALL include a stable `northbound_job_id`
- **AND** each target SHALL include callback URL, path, token, and token header metadata
- **AND** the plugin SHALL be able to return a deferred webhook-only result without scheduling a poll

#### Scenario: Plugin registers signed external webhook callback
- **GIVEN** an approved Wasm action invokes an external API that can sign webhook bodies
- **WHEN** ServiceRadar dispatches the launch request for a target using HMAC callback mode
- **THEN** the target callback metadata SHALL include signing algorithm, timestamp header, signature header, and HMAC mode fields
- **AND** the plugin SHALL be able to register those values with the external system
- **AND** the plugin SHALL be able to return a deferred webhook-only result without scheduling a poll

#### Scenario: External system posts token-only callback result
- **GIVEN** a deferred target has token-only callback metadata
- **WHEN** the external system posts a callback result with the correct job ID and token
- **THEN** ServiceRadar SHALL update only that target
- **AND** ServiceRadar SHALL recompute the parent invocation state from all targets

#### Scenario: External system posts signed callback result
- **GIVEN** a deferred target requires HMAC callback verification
- **WHEN** the external system posts a callback result with the correct job ID, token, timestamp, and HMAC-SHA256 signature
- **THEN** ServiceRadar SHALL verify the signature against the raw request body
- **AND** ServiceRadar SHALL update only that target
- **AND** ServiceRadar SHALL recompute the parent invocation state from all targets

#### Scenario: External system posts invalid callback token
- **GIVEN** a deferred target has callback metadata
- **WHEN** a callback request has a missing or invalid token
- **THEN** ServiceRadar SHALL reject the request without updating target state

#### Scenario: External system posts invalid signed callback
- **GIVEN** a deferred target requires HMAC callback verification
- **WHEN** a callback request has a missing signature, invalid signature, or timestamp outside the accepted tolerance window
- **THEN** ServiceRadar SHALL reject the request without updating target state
