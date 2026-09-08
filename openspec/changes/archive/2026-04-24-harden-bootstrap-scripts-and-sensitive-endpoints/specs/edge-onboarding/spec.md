## MODIFIED Requirements
### Requirement: Downloadable Installation Bundle

The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script

#### Scenario: Generated install scripts treat package data as literal values
- **GIVEN** an edge or collector onboarding package contains operator-provided metadata such as site, hostname, or component labels
- **WHEN** the system generates an install or update shell script
- **THEN** embedded values SHALL be encoded so shell metacharacters are treated as literal data
- **AND** generated scripts SHALL NOT execute command substitutions or other shell payloads from those values

#### Scenario: Bundle generation failure does not leak internal error terms
- **GIVEN** an edge or collector bundle request fails during tarball generation
- **WHEN** the API returns an error response
- **THEN** the client response SHALL contain a stable client-safe error message
- **AND** internal exception terms or inspected server data SHALL NOT be exposed in the response body
