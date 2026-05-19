## ADDED Requirements
### Requirement: Timestamped HMAC Webhook Verification
The system SHALL support timestamped HMAC-SHA256 verification for inbound webhook callbacks that opt into signed request handling. Verification MUST use the raw request body, a configured timestamp header, a configured signature header, and a per-target signing secret. Signature comparisons MUST use constant-time comparison. Signed callbacks MUST be rejected when the timestamp is missing, malformed, outside the configured tolerance window, or when the computed signature does not match the supplied signature.

#### Scenario: Valid signed webhook accepted
- **GIVEN** an inbound callback target requires HMAC-SHA256 verification
- **WHEN** the request includes a valid token, timestamp, and signature over `<timestamp>.<raw_body>`
- **THEN** the system SHALL accept the callback for normal result processing

#### Scenario: Invalid signature rejected
- **GIVEN** an inbound callback target requires HMAC-SHA256 verification
- **WHEN** the request includes an invalid signature
- **THEN** the system SHALL reject the callback
- **AND** the target state SHALL NOT be updated

#### Scenario: Stale timestamp rejected
- **GIVEN** an inbound callback target requires HMAC-SHA256 verification
- **WHEN** the request timestamp is outside the configured tolerance window
- **THEN** the system SHALL reject the callback
- **AND** the target state SHALL NOT be updated

#### Scenario: Token-only webhook remains supported
- **GIVEN** an inbound callback target is configured for token-only callback verification
- **WHEN** the request includes the correct callback token without HMAC headers
- **THEN** the system SHALL accept the callback for normal result processing
