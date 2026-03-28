## MODIFIED Requirements

### Requirement: Structured onboarding tokens are integrity protected
The system SHALL protect structured onboarding tokens against tampering before enrollment clients trust embedded metadata such as package identifier, download token, or Core API endpoint. Signed structured tokens SHALL be the primary format for both agent and collector enrollment. Legacy unsigned tokens SHALL NOT be allowed to supply a trusted Core API endpoint.

#### Scenario: Collector client rejects a tampered structured token
- **GIVEN** a structured collector enrollment token has been modified after issuance
- **WHEN** the collector enrollment client parses the token
- **THEN** the client rejects the token before attempting bundle download
- **AND** the client does not trust the embedded Core API endpoint

#### Scenario: Legacy unsigned collector token requires a separately trusted Core API URL
- **GIVEN** an operator uses a legacy unsigned collector enrollment token
- **WHEN** the collector enrollment client parses the token
- **THEN** the client does not trust any embedded Core API endpoint from that token
- **AND** enrollment requires a separately trusted Core API URL such as `--core-url`
