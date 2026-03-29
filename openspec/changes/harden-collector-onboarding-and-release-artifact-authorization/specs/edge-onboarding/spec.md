## MODIFIED Requirements

### Requirement: Structured onboarding tokens are integrity protected
The system SHALL protect structured onboarding tokens against tampering before enrollment clients trust embedded metadata such as package identifier, download token, or Core API endpoint. Signed structured tokens SHALL be the only supported format for both agent and collector enrollment.

#### Scenario: Collector client rejects a tampered structured token
- **GIVEN** a structured collector enrollment token has been modified after issuance
- **WHEN** the collector enrollment client parses the token
- **THEN** the client rejects the token before attempting bundle download
- **AND** the client does not trust the embedded Core API endpoint

#### Scenario: Client rejects an unsigned collector token format
- **GIVEN** an operator uses an unsigned collector enrollment token
- **WHEN** the collector enrollment client parses the token
- **THEN** the client rejects the token before attempting enrollment
- **AND** the client does not fall back to any unsigned compatibility parser
